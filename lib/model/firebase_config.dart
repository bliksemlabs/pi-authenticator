/*
  privacyIDEA Authenticator

  Authors: Timo Sturm <timo.sturm@netknights.it>

  Copyright (c) 2017-2019 NetKnights GmbH

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

import 'package:json_annotation/json_annotation.dart';

part 'firebase_config.g.dart';

@JsonSerializable()
class FirebaseConfig {
  String _projectID;
  String _projectNumber;
  String _appID;
  String _apiKey;

  FirebaseConfig(
      {String projectID, String projectNumber, String appID, String apiKey})
      : this._projectID = projectID,
        this._projectNumber = projectNumber,
        this._appID = appID,
        this._apiKey = apiKey;

  get projectID => _projectID;

  get projectNumber => _projectNumber;

  get appID => _appID;

  get apiKey => _apiKey;

  factory FirebaseConfig.fromJson(Map<String, dynamic> json) =>
      _$FirebaseConfigFromJson(json);

  Map<String, dynamic> toJson() => _$FirebaseConfigToJson(this);

  bool operator ==(fc) =>
      fc is FirebaseConfig &&
      fc.projectID == projectID &&
      fc.projectNumber == projectNumber &&
      fc.appID == appID &&
      fc.apiKey == apiKey;

  int get hashCode => projectID.hashCode ^ projectNumber.hashCode;

  @override
  String toString() {
    return 'FirebaseConfig{_projectID: $_projectID,'
        ' _projectNumber: $_projectNumber, _appID: $_appID, _apiKey: $_apiKey}';
  }
}
