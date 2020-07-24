/*
  privacyIDEA Authenticator

  Authors: Timo Sturm <timo.sturm@netknights.it>

  Copyright (c) 2017-2020 NetKnights GmbH

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
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:barcode_scan/barcode_scan.dart';
import 'package:base32/base32.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutterlifecyclehooks/flutterlifecyclehooks.dart';
import 'package:package_info/package_info.dart';
import 'package:passcode_screen/circle.dart';
import 'package:passcode_screen/keyboard.dart';
import 'package:passcode_screen/passcode_screen.dart';
import 'package:privacyidea_authenticator/model/firebase_config.dart';
import 'package:privacyidea_authenticator/model/tokens.dart';
import 'package:privacyidea_authenticator/screens/add_manually_screen.dart';
import 'package:privacyidea_authenticator/screens/custom_license_screen.dart';
import 'package:privacyidea_authenticator/screens/settings_screen.dart';
import 'package:privacyidea_authenticator/utils/application_theme_utils.dart';
import 'package:privacyidea_authenticator/utils/crypto_utils.dart';
import 'package:privacyidea_authenticator/utils/identifiers.dart';
import 'package:privacyidea_authenticator/utils/license_utils.dart';
import 'package:privacyidea_authenticator/utils/localization_utils.dart';
import 'package:privacyidea_authenticator/utils/storage_utils.dart';
import 'package:privacyidea_authenticator/utils/utils.dart';
import 'package:privacyidea_authenticator/widgets/token_widgets.dart';
import 'package:privacyidea_authenticator/widgets/two_step_dialog.dart';
import 'package:uuid/uuid.dart';

class MainScreen extends StatefulWidget {
  MainScreen({Key key, this.title}) : super(key: key);
  final String title;

  @override
  _MainScreenState createState() => _MainScreenState();
}

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

class _MainScreenState extends State<MainScreen> with LifecycleMixin {
  List<Token> _tokenList = List<Token>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _isAppUnlocked = false;
  bool _isCheckingForPIN = false;
  final StreamController<bool> _verificationNotifier =
      StreamController<bool>.broadcast();

  _MainScreenState() {
    _checkPIN();
    _loadAllTokens();
    _loadFirebase();
  }

  @override
  void onPause() {
    setState(() {
      _isAppUnlocked = false;
    });
  }

  @override
  void onResume() {
    _checkPIN();
  }

  // TODO
  //  Style pin input
  //  Hide stuff in background on iOS
  _checkPIN() async {
    if (_isCheckingForPIN) return;
    _isCheckingForPIN = true;

    if (!await StorageUtil.isPINSet()) {
      setState(() => _isAppUnlocked = true);
      _isCheckingForPIN = false;
      return;
    }

    if (!_isAppUnlocked) _askForPIN();
  }

  _askForPIN() async {
    int numberOfDigits = (await StorageUtil.getPIN()).length;

    Navigator.push(
        context,
        PageRouteBuilder(
          opaque: false,
          pageBuilder: (context, animation, secondaryAnimation) => WillPopScope(
            onWillPop: () async => _isAppUnlocked,
            child: buildPasscodeScreen(
                context, numberOfDigits, _onPINEntered, _verificationNotifier),
          ),
        ));
  }

  _onPINEntered(String enteredPIN) async {
    bool isValid = (await StorageUtil.getPIN()) == enteredPIN;
    _verificationNotifier.add(isValid);
    if (isValid) {
      _isCheckingForPIN = false;
      setState(() {
        this._isAppUnlocked = isValid;
      });
    }
  }

  _loadFirebase() async {
    // If no push tokens exist, the firebase config should be deleted here.
    if (!(await StorageUtil.loadAllTokens())
        .any((element) => element is PushToken)) {
      StorageUtil.deleteGlobalFirebaseConfig();
      return;
    }

    if (await StorageUtil.globalFirebaseConfigExists()) {
      _initFirebase(await StorageUtil.loadGlobalFirebaseConfig());
    }
  }

  _loadAllTokens() async {
    List<Token> list = await StorageUtil.loadAllTokens();
    setState(() {
      this._tokenList = list;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(
          widget.title,
          textScaleFactor: screenTitleScaleFactor,
        ),
        actions: _buildActionMenu(),
        leading: Padding(
          padding: EdgeInsets.all(4.0),
          child: Image.asset('res/logo/app_logo_light.png'),
        ),
      ),
      body: _isAppUnlocked ? _buildTokenList() : Column(),
      floatingActionButton: _isAppUnlocked
          ? FloatingActionButton(
              onPressed: () => _scanQRCode(),
              tooltip: LTen.of(context).scanQRTooltip,
              child: Icon(Icons.add),
            )
          : null,
    );
  }

  _scanQRCode() async {
    try {
      String barcode = await BarcodeScanner.scan();
      log(
        "Barcode scanned:",
        name: "main_screen.dart",
        error: barcode,
      );

      Token newToken = await _buildTokenFromMap(
          parseQRCodeToMap(barcode), Uri.parse(barcode));
      setState(() {
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

        _tokenList.add(newToken);
      });
    } on PlatformException catch (e) {
      if (e.code == BarcodeScanner.CameraAccessDenied) {
        //  Camera access was denied
      } else {
        //  Unknown error
        throw e;
      }
    } on FormatException {
      //  User returned by pressing the back button
    } on ArgumentError catch (e) {
      // Error while parsing qr code.
      // Show the error message to the user.
      _showMessage(
          "${e.message}\n Please inform the creator of this qr code about the problem.",
          Duration(seconds: 8));
      log(
        "Malformed QR code:",
        name: "main_screen.dart",
        error: e.toString(),
      );

      print(e.stackTrace);
    } catch (e) {
      //  Unknown error
      throw e;
    }
  }

  Future<Token> _buildTokenFromMap(Map<String, dynamic> uriMap, Uri uri) async {
    String uuid = Uuid().v4();
    String type = uriMap[URI_TYPE];

    // Push token do not need any of the other parameters.
    if (equalsIgnoreCase(type, enumAsString(TokenTypes.PIPUSH))) {
      return _buildPushToken(uriMap, uuid);
    }

    String label = uriMap[URI_LABEL];
    String algorithm = uriMap[URI_ALGORITHM];
    int digits = uriMap[URI_DIGITS];
    Uint8List secret = uriMap[URI_SECRET];
    int counter = uriMap[URI_COUNTER];
    int period = uriMap[URI_PERIOD];
    String issuer = uriMap[URI_ISSUER];

    if (is2StepURI(uri)) {
      // Calculate the whole secret.
      secret = await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) => TwoStepDialog(
          iterations: uriMap[URI_ITERATIONS],
          keyLength: uriMap[URI_OUTPUT_LENGTH_IN_BYTES],
          saltLength: uriMap[URI_SALT_LENGTH],
          password: secret,
        ),
      );
    }

    // uri.host -> totp or hotp
    if (type == "hotp") {
      return HOTPToken(
        label: label,
        issuer: issuer,
        id: uuid,
        algorithm: mapStringToAlgorithm(algorithm),
        digits: digits,
        secret: encodeSecretAs(secret, Encodings.base32),
        counter: counter,
      );
    } else if (type == "totp") {
      return TOTPToken(
        label: label,
        issuer: issuer,
        id: uuid,
        algorithm: mapStringToAlgorithm(algorithm),
        digits: digits,
        secret: encodeSecretAs(secret, Encodings.base32),
        period: period,
      );
    } else {
      throw ArgumentError.value(
          uri,
          "uri",
          "Building the token type "
              "[$type] is not a supported right now.");
    }
  }

  Future<PushToken> _buildPushToken(
      Map<String, dynamic> uriMap, String uuid) async {
    FirebaseConfig config = FirebaseConfig(
        projectID: uriMap[URI_PROJECT_ID],
        projectNumber: uriMap[URI_PROJECT_NUMBER],
        appID: Platform.isIOS ? uriMap[URI_APP_ID_IOS] : uriMap[URI_APP_ID],
        apiKey: Platform.isIOS ? uriMap[URI_API_KEY_IOS] : uriMap[URI_API_KEY]);

    PushToken token = PushToken(
      serial: uriMap[URI_SERIAL],
      label: uriMap[URI_LABEL],
      issuer: uriMap[URI_ISSUER],
      id: uuid,
      sslVerify: uriMap[URI_SSL_VERIFY],
      expirationDate: DateTime.now().add(Duration(minutes: uriMap[URI_TTL])),
      enrollmentCredentials: uriMap[URI_ENROLLMENT_CREDENTIAL],
      url: uriMap[URI_ROLLOUT_URL],
    );

    // Save the config for this token to use it when rolling out.
    await StorageUtil.saveOrReplaceFirebaseConfig(token, config);

    print('Config for token: ${await StorageUtil.loadFirebaseConfig(token)}');

    return token;
  }

  Future<String> _initFirebase(FirebaseConfig config) async {
    ArgumentError.checkNotNull(config, "config");

    log("Initializing firebase.", name: "main_screen.dart");

    // Used to identify a firebase app, this is nothing more than an id.
    final String name = "privacyidea_authenticator";

    if (!await StorageUtil.globalFirebaseConfigExists() ||
        await StorageUtil.loadGlobalFirebaseConfig() == config) {
      log("Creating firebaseApp from config.",
          name: "main_screen.dart", error: config);

      await FirebaseApp.configure(
        name: name,
        options: FirebaseOptions(
          googleAppID: config.appID,
          apiKey: config.apiKey,
          databaseURL: "https://" + config.projectID + ".firebaseio.com",
          storageBucket: config.projectID + ".appspot.com",
          projectID: config.projectID,
          gcmSenderID: config.projectNumber,
        ),
      );

      // TODO Check if it is already initialized?
      var initializationSettingsAndroid =
          AndroidInitializationSettings('app_icon');
      var initializationSettingsIOS = IOSInitializationSettings();
      var initializationSettings = InitializationSettings(
          initializationSettingsAndroid, initializationSettingsIOS);
      await flutterLocalNotificationsPlugin.initialize(initializationSettings);
    } else if (await StorageUtil.loadGlobalFirebaseConfig() != config) {
      log("Given firebase config does not equal the existing config.",
          name: "main_screen.dart",
          error: "Existing: ${await StorageUtil.loadGlobalFirebaseConfig()}"
              "\n Given:    $config");

      return null;
    }

    FirebaseMessaging firebaseMessaging = FirebaseMessaging()
      ..setApplicationName(name);

    // Ask user to allow notifications, if declined no notifications are shown
    //  for incomming push requests.
    if (Platform.isIOS) {
      await firebaseMessaging.requestNotificationPermissions();
    }

    // FIXME: onResume and onLaunch is not configured see:
    //  https://pub.dev/packages/firebase_messaging#-readme-tab-
    //  but the solution there does not seem to work?
    //  These functions do not seem to serve a purpose, as the background
    //  message handling seems to do just that.
    firebaseMessaging.configure(
      onMessage: (Map<String, dynamic> message) async {
        // Used by Android and iOS
        print("onMessage: ");
        _handleIncomingAuthRequest(message);
      },
      onLaunch: (Map<String, dynamic> message) async {
        // Does not seem to be used by Android or iOS
        print("onLaunch: ");
        _handleIncomingAuthRequest(message);
      },
      onResume: (Map<String, dynamic> message) async {
        // Used by iOS only (?)
        print("onResume: ");
        _handleIncomingAuthRequest(message);
      },
      onBackgroundMessage: Platform.isIOS
          ? null
          : // iOS does not support this.
          myBackgroundMessageHandler,
    );

    String firebaseToken = await firebaseMessaging.getToken();

    log("Firebase initialized, token added",
        name: "main_screen.dart", error: firebaseToken);

    StorageUtil.saveOrReplaceGlobalFirebaseConfig(config);

    // The Firebase Plugin will throw a network exception, but that does not reach
    //  the flutter part of the app. That is why we need to throw our own socket-
    //  exception in this case.
    if (firebaseToken == null)
      throw SocketException(
          "Firebase token could not be retrieved, the only know cause of this is"
          " that the firebase servers could not be reached.");

    return firebaseToken;
  }

  static Future<dynamic> myBackgroundMessageHandler(
      Map<String, dynamic> message) async {
    log("Background message received.",
        name: "main_screen.dart", error: message);
    _handleIncomingRequest(message, await StorageUtil.loadAllTokens(), true);
  }

  void _handleIncomingAuthRequest(Map<String, dynamic> message) {
    log("Foreground message received.",
        name: "main_screen.dart", error: message);
    setState(() async {
      _handleIncomingRequest(message, await StorageUtil.loadAllTokens(), false);
      _loadAllTokens();
    });
  }

  static void _handleIncomingRequest(
      Map<String, dynamic> message, List<Token> tokenList, bool inBackground) {
    var data = Platform.isIOS ? message : message['data'];

    Uri requestUri = Uri.parse(data['url']);
    String requestedSerial = data['serial'];

    log('Incoming push auth request for token with serial.',
        name: 'main_screen.dart', error: requestedSerial);

    bool wasHandled = false;

    tokenList.forEach((token) {
      if (token is PushToken) {
        if (token.serial == requestedSerial && token.isRolledOut) {
          log('Token matched requested token',
              name: 'main_screen.dart', error: token);
          String signature = data['signature'];
          String signedData = '${data['nonce']}|'
              '${data['url']}|'
              '${data['serial']}|'
              '${data['question']}|'
              '${data['title']}|'
              '${data['sslverify']}';

          if (verifyRSASignature(token.getPublicServerKey(),
              utf8.encode(signedData), base32.decode(signature))) {
            wasHandled = true;

            log('Validating incoming message was successful.',
                name: 'main_screen.dart');

            PushRequest pushRequest = PushRequest(
                data['title'],
                data['question'],
                requestUri,
                data['nonce'],
                data['sslverify'] == '1' ? true : false,
                data['nonce'].hashCode,
                expirationDate: DateTime.now().add(
                  Duration(minutes: 2),
                )); // Push requests expire after 2 minutes.

            if (!token.pushRequests.contains(pushRequest)) {
              token.pushRequests.add(pushRequest);

              StorageUtil.saveOrReplaceToken(
                  token); // Save the pending request.

              if (inBackground) _showNotification(token, pushRequest, false);
            } else {
              log(
                  "The push request $pushRequest already exists "
                  "for the token $token",
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
    });

    if (!wasHandled) {
      log("The requested token does not exist or is not rolled out.",
          name: "main_screen.dart", error: requestedSerial);
    }
  }

  static void _showNotification(
      PushToken token, PushRequest pushRequest, bool silent) async {
    var iOSPlatformChannelSpecifics =
        IOSNotificationDetails(presentSound: !silent);

    // TODO configure - Do we need channel ids?
    var bigTextStyleInformation = BigTextStyleInformation(pushRequest.question,
        htmlFormatBigText: true,
        contentTitle: pushRequest.title,
        htmlFormatContentTitle: true,
        summaryText: 'Token <i>${token.label}</i>',
        htmlFormatSummaryText: true);
    var androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'your channel id',
      'your channel name',
      'your channel description',
      ticker: 'ticker',
      playSound: silent,
      styleInformation: bigTextStyleInformation, // To display token name.
    );

    await flutterLocalNotificationsPlugin.show(
      pushRequest.id.hashCode, // ID of the notification
      pushRequest.title,
      pushRequest.question,
      NotificationDetails(
          androidPlatformChannelSpecifics, iOSPlatformChannelSpecifics),
    );
  }

  ListView _buildTokenList() {
    return ListView.separated(
        itemBuilder: (context, index) {
          Token token = _tokenList[index];
          return TokenWidget(
            token,
            onDeleteClicked: () => _removeToken(token),
            getFirebaseToken: (config) => _initFirebase(config),
          );
        },
        separatorBuilder: (context, index) {
          return Divider();
        },
        itemCount: _tokenList.length);
  }

  void _removeToken(Token token) async {
    await StorageUtil.deleteToken(token);

    if (!(await StorageUtil.loadAllTokens())
        .any((element) => element is PushToken)) {
      StorageUtil.deleteGlobalFirebaseConfig();
    }

    setState(() {
      print("Remove: $token");
      _tokenList.remove(token);
    });
  }

  List<Widget> _buildActionMenu() {
    // TODO maybe a drawer / 'hamburger' menu would be nicer?
    return <Widget>[
      PopupMenuButton<String>(
        onSelected: (String value) async {
          if (value == "about") {
            PackageInfo info = await PackageInfo.fromPlatform();
//            clearLicenses(); // This is used for testing purposes only.
            addAllLicenses();
            Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
//                        LicensePage(
//                          applicationName: "privacyIDEA Authenticator",
//                          applicationVersion: info.version,
//                          applicationIcon: Padding(
//                            padding: EdgeInsets.all(40.0),
//                            child: Image.asset('res/logo/app_logo_light.png'),
//                          ),
//                          applicationLegalese: "Apache License 2.0",
//                        )
                      CustomLicenseScreen(),
                ));
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
                  builder: (context) => SettingsScreen('Settings'),
                ));
          }
        },
        elevation: 5.0,
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          PopupMenuItem<String>(
            value: "about",
            child: Text(LTen.of(context).about),
          ),
          PopupMenuDivider(),
          PopupMenuItem<String>(
            value: "add_manually",
            child: Text(LTen.of(context).addManually),
          ),
          PopupMenuDivider(),
          PopupMenuItem<String>(
            value: "settings",
            child: Text(LTen.of(context).settings),
          ),
        ],
      ),
    ];
  }

  _addToken(Token newToken) {
    log("Adding new token:", name: "main_screen.dart", error: newToken);
    if (newToken != null) {
      setState(() {
        _tokenList.add(newToken);
      });
    }
  }

  _showMessage(String message, Duration duration) {
    _scaffoldKey.currentState.showSnackBar(SnackBar(
      content: Text(message),
      duration: duration,
    ));
  }
}

PasscodeScreen buildPasscodeScreen(
    BuildContext context,
    final int numberOfDigits,
    final PasswordEnteredCallback passwordEnteredCallback,
    final StreamController<bool> verificationNotifier,
    {final bool allowCancel = false}) {
  return PasscodeScreen(
    title: Text(
      'Unlock App', // TODO Translate
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.white, fontSize: 28),
    ),
    passwordDigits: numberOfDigits,
    circleUIConfig: CircleUIConfig(
        borderColor: Colors.blue, // TODO Style
        fillColor: Colors.blue,
        circleSize: 30),
    keyboardUIConfig:
        KeyboardUIConfig(digitBorderWidth: 2, primaryColor: Colors.blue),
    // TODO Style
    passwordEnteredCallback: passwordEnteredCallback,
    cancelButton: Text(allowCancel ? LTen.of(context).cancel : ""),
    deleteButton: Text(
      LTen.of(context).delete,
      style: const TextStyle(fontSize: 16, color: Colors.white),
      semanticsLabel: LTen.of(context).cancel,
    ),
    shouldTriggerVerification: verificationNotifier.stream,
    backgroundColor: Colors.black.withOpacity(0.8),
    cancelCallback: allowCancel ? () => Navigator.of(context).pop() : null,
    digits: ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
  );
}
