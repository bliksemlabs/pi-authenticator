/*
  privacyIDEA Authenticator

  Authors: Timo Sturm <timo.sturm@netknights.it>

  Copyright (c) 2017-2021 NetKnights GmbH

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/

import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:typed_data';

import 'package:base32/base32.dart';
import 'package:collection/collection.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutterlifecyclehooks/flutterlifecyclehooks.dart';
import 'package:package_info/package_info.dart';
import 'package:pi_authenticator_legacy/pi_authenticator_legacy.dart';
import 'package:privacyidea_authenticator/model/tokens.dart';
import 'package:privacyidea_authenticator/screens/add_manually_screen.dart';
import 'package:privacyidea_authenticator/screens/changelog_screen.dart';
import 'package:privacyidea_authenticator/screens/guide_screen.dart';
import 'package:privacyidea_authenticator/screens/scanner_screen.dart';
import 'package:privacyidea_authenticator/screens/settings_screen.dart';
import 'package:privacyidea_authenticator/utils/crypto_utils.dart';
import 'package:privacyidea_authenticator/utils/identifiers.dart';
import 'package:privacyidea_authenticator/utils/license_utils.dart';
import 'package:privacyidea_authenticator/utils/parsing_utils.dart';
import 'package:privacyidea_authenticator/utils/push_provider.dart';
import 'package:privacyidea_authenticator/utils/storage_utils.dart';
import 'package:privacyidea_authenticator/widgets/token_widgets.dart';
import 'package:privacyidea_authenticator/widgets/two_step_dialog.dart';
import 'package:uni_links/uni_links.dart';

import 'custom_about_screen.dart';

class MainScreen extends StatefulWidget {
  MainScreen({Key? key, required this.title}) : super(key: key);
  final String title;

  @override
  _MainScreenState createState() => _MainScreenState();
}

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

class _MainScreenState extends State<MainScreen> with LifecycleMixin {
  List<Token> _tokenList = [];
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _pollTimer;

  // Used for handling links the app is registered to handle.
  StreamSubscription? _uniLinkStream;

  @override
  void initState() {
    super.initState();
    _initLinkHandling();
    _initStateAsync();
  }

  void _initStateAsync() async {
    await PushProvider.initialize(
      handleIncomingMessage: (RemoteMessage message) =>
          _handleIncomingAuthRequest(message),
      backgroundMessageHandler: _firebaseMessagingBackgroundHandler,
    );
    _startPollingIfEnabled();
    await PushProvider.updateFbTokenIfChanged();
  }

  @override
  void afterFirstRender() {
    _showChangelogAndGuide();
    _loadTokenList();
  }

  @override
  void onPause() {}

  @override
  void onResume() {}

  @override
  void dispose() {
    _pollTimer?.cancel();
    _uniLinkStream?.cancel();
    super.dispose();
  }

  Future<void> _initLinkHandling() async {
    _uniLinkStream = linkStream.listen((String? link) {
      _handleOthAuthUri(link);
    }, onError: (err) {
      _showMessage(AppLocalizations.of(context)!.handlingOtpAuthLinkFailed,
          Duration(seconds: 4));
    });

    try {
      String? link = await getInitialLink();
      if (link == null) {
        return; // Do not cause an Exception here if no link exists.
      }
      _handleOthAuthUri(link);
    } on PlatformException {
      _showMessage(AppLocalizations.of(context)!.handlingOtpAuthLinkFailed,
          Duration(seconds: 4));
    }
  }

  void _startPollingIfEnabled() {
    AppSettings.of(context).streamEnablePolling().listen(
      (bool event) {
        if (event) {
          log('Polling is enabled.', name: 'main_screen.dart');

          _pollTimer = Timer.periodic(Duration(seconds: 3),
              (_) => PushProvider.pollForRequests(context));
          PushProvider.pollForRequests(context);
        } else {
          log('Polling is disabled.', name: 'main_screen.dart');
          _pollTimer?.cancel();
          _pollTimer = null;
        }
      },
      cancelOnError: false,
      onError: (error) => log('$error', name: 'polling timer'),
    );
  }

  /// Handles incoming push requests by verifying the challenge and adding it
  /// to the token. This should be guarded by a lock.
  static Future<void> _handleIncomingRequest(
      RemoteMessage message, List<Token> tokenList, bool inBackground) async {
    var data = message.data;

    Uri requestUri = Uri.parse(data['url']);
    String requestedSerial = data['serial'];

    log('Incoming push auth request for token with serial.',
        name: 'main_screen.dart', error: requestedSerial);

    PushToken? token = tokenList
        .whereType<PushToken>()
        .firstWhereOrNull((t) => t.serial == requestedSerial && t.isRolledOut);

    if (token == null) {
      log("The requested token does not exist or is not rolled out.",
          name: "main_screen.dart", error: requestedSerial);
    } else {
      log('Token matched requested token',
          name: 'main_screen.dart', error: token);
      String signature = data['signature'];
      String signedData = '${data['nonce']}|'
          '$requestUri|'
          '${data['serial']}|'
          '${data['question']}|'
          '${data['title']}|'
          '${data['sslverify']}';

      bool sslVerify = (int.tryParse(data['sslverify']) ?? 0) == 1;

      // Re-add url and sslverify to android legacy tokens:
      token.url ??= requestUri;
      token.sslVerify ??= sslVerify;

      bool isVerified = token.privateTokenKey == null
          ? await Legacy.verify(token.serial, signedData, signature)
          : verifyRSASignature(token.getPublicServerKey()!,
              utf8.encode(signedData) as Uint8List, base32.decode(signature));

      if (isVerified) {
        log('Validating incoming message was successful.',
            name: 'main_screen.dart');

        PushRequest pushRequest = PushRequest(
            title: data['title'],
            question: data['question'],
            uri: requestUri,
            nonce: data['nonce'],
            sslVerify: sslVerify,
            id: data['nonce'].hashCode,
            // FIXME This is not guaranteed to not lead to collisions, but they might be unlikely in this case.
            expirationDate: DateTime.now().add(
              Duration(minutes: 2),
            )); // Push requests expire after 2 minutes.

        if (!token.knowsRequestWithId(pushRequest.id)) {
          token.pushRequests.add(pushRequest);
          token.knownPushRequests.put(pushRequest.id);

          StorageUtil.saveOrReplaceToken(token); // Save the pending request.
          PushProvider.showNotification(token, pushRequest, false);
        } else {
          log(
              "The push request $pushRequest already exists "
              "for the token with serial ${token.serial}",
              name: "main_screen.dart");
        }
      } else {
        log('Validating incoming message failed.',
            name: 'main_screen.dart',
            error:
                'Signature $signature does not match signed data: $signedData');
      }
    }
  }

  Future<void> _handleIncomingAuthRequest(RemoteMessage message) async {
    log("Foreground message received.",
        name: "main_screen.dart", error: message);
    await StorageUtil.protect(() async => _handleIncomingRequest(
        message, await StorageUtil.loadAllTokens(), false));
    await _loadTokenList(); // Update UI
  }

  void _showChangelogAndGuide() async {
    // Do not show these info when running driver tests
    if (!AppSettings.of(context).isTestMode) {
      PackageInfo info = await PackageInfo.fromPlatform();

      // Check if the app was updated
      if (info.version != await StorageUtil.getCurrentVersion()) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => ChangelogScreen()),
        );
        StorageUtil.setCurrentVersion(info.version);
      }

      // Show the guide screen in front of the changelog -> load it last
      if (AppSettings.of(context).showGuideOnStart) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => GuideScreen()),
        );
      }
    }
  }

  static Future<void> _firebaseMessagingBackgroundHandler(
      RemoteMessage message) async {
    log("Background message received.",
        name: "main_screen.dart", error: message);
    await StorageUtil.protect(() async => _handleIncomingRequest(
        message, await StorageUtil.loadAllTokens(), true));
  }

  Future<void> _loadTokenList() async {
    List<Token> l1 = await StorageUtil.loadAllTokens();
    // Prevent the list items from skipping around on ui updates
    l1.sort((a, b) => a.id.hashCode.compareTo(b.id.hashCode));
    this._tokenList = l1;

    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(
          widget.title,
          overflow: TextOverflow.ellipsis,
          // maxLines: 2 only works like this.
          maxLines: 2, // Title can be shown on small screens too.
        ),
        actions: _buildActionMenu(),
        leading: SvgPicture.asset('res/logo/app_logo_light.svg'),
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _scanQRCode(),
        tooltip: AppLocalizations.of(context)!.scanQrCode,
        child: Icon(Icons.add),
      ),
    );
  }

  void _handleOthAuthUri(String? otpAuth) async {
    if (otpAuth == null) {
      return;
    }

    log(
      "Try to handle otpAuth:",
      name: "main_screen.dart",
      error: otpAuth,
    );

    try {
      // TODO get crash report recipients from map and set in settings
      //  and for Catcher.
      Map<String, dynamic> uriMap = parseOtpAuthUriToMap(otpAuth);
      // AppSetting.of(context).add...
//      Catcher.instance.updateConfig();

      if (is2StepToken(uriMap)) {
        // Calculate the whole secret.
        uriMap[URI_SECRET] = (await showDialog<Uint8List>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) => TwoStepDialog(
            iterations: uriMap[URI_ITERATIONS],
            keyLength: uriMap[URI_OUTPUT_LENGTH_IN_BYTES],
            saltLength: uriMap[URI_SALT_LENGTH],
            password: uriMap[URI_SECRET],
          ),
        ))!;
      }

      Token newToken = buildTokenFromMap(uriMap);

      log(
        "Adding new token from qr-code:",
        name: "main_screen.dart",
        error: newToken,
      );

      if (newToken is PushToken && _tokenList.contains(newToken)) {
        _showMessage(
            "A token with the serial ${newToken.serial} already exists!",
            Duration(seconds: 2));
        return;
      }

      await StorageUtil.saveOrReplaceToken(newToken);
      await PushProvider.initNotifications();
      _tokenList.add(newToken);

      if (mounted) {
        setState(() {});
      }
    } on ArgumentError catch (e) {
      // Error while parsing qr code.
      _showMessage(
          "${e.message}\n Please inform the creator of this qr code about the problem.",
          Duration(seconds: 8));
      log(
        "Malformed QR code:",
        name: "main_screen.dart",
        error: e.stackTrace,
      );
    }
  }

  void _scanQRCode() async {
    String? qr = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => QRScannerScreen()),
    );
    _handleOthAuthUri(qr);
  }

  /// Builds the body of the screen. If any tokens supports polling,
  /// returns a list wrapped in a RefreshIndicator to manually poll.
  /// If not returns the list only.
  Widget _buildBody() {
    ListView list = ListView.separated(
        itemBuilder: (context, index) {
          Token token = _tokenList[index];
          return TokenWidget(token, onDeleteClicked: () => _removeToken(token));
        },
        separatorBuilder: (context, index) {
          return Divider();
        },
        itemCount: _tokenList.length);

    bool allowManualRefresh =
        _tokenList.any((t) => t is PushToken && t.url != null);

    return allowManualRefresh
        ? RefreshIndicator(
            child: list,
            onRefresh: () async {
              _showMessage(AppLocalizations.of(context)!.pollingChallenges,
                  Duration(seconds: 1));
              bool success = await PushProvider.pollForRequests(context);
              if (!success) {
                _showMessage(
                  AppLocalizations.of(context)!.pollingFailNoNetworkConnection,
                  Duration(seconds: 3),
                );
              }
            },
          )
        : list;
  }

  void _addToken(Token token) async {
    log("Adding new token:", name: "main_screen.dart", error: token);
    await StorageUtil.saveOrReplaceToken(token);
    _tokenList.add(token);

    if (mounted) {
      setState(() {});
    }
  }

  void _removeToken(Token token) async {
    log("Remove: $token");
    await StorageUtil.deleteToken(token);
    await _loadTokenList();
  }

  List<Widget> _buildActionMenu() {
    return <Widget>[
      PopupMenuButton<String>(
        onSelected: (String value) async {
          if (value == "about") {
//              clearLicenses(), // This is used for testing purposes only.
            addAllLicenses();
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => CustomLicenseScreen(),
              ),
            );
          } else if (value == "add_manually") {
            Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AddTokenManuallyScreen(),
                )).then((newToken) => _addToken(newToken));
          } else if (value == "settings") {
            Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsScreen(),
                )).then((_) => _loadTokenList());
          } else if (value == 'guide') {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => GuideScreen(),
              ),
            );
          }
        },
        elevation: 5.0,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: "add_manually",
            child: Text(AppLocalizations.of(context)!.addToken),
          ),
          PopupMenuDivider(),
          PopupMenuItem<String>(
            value: "settings",
            child: Text(AppLocalizations.of(context)!.settings),
          ),
          PopupMenuDivider(),
          PopupMenuItem<String>(
            value: "about",
            child: Text(AppLocalizations.of(context)!.about),
          ),
          PopupMenuDivider(),
          PopupMenuItem<String>(
            value: "guide",
            child: Text(AppLocalizations.of(context)!.guide),
          ),
        ],
      ),
    ];
  }

  void _showMessage(String message, Duration duration) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: duration,
    ));
  }
}
