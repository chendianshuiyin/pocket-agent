enum SshAuthentication { password, privateKey }

class ServerProfile {
  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    required this.authentication,
    this.hostKeyType,
    this.hostKeyFingerprint,
    this.remoteCodexPort = 4500,
  }) : assert(port > 0 && port <= 65535),
       assert(remoteCodexPort > 0 && remoteCodexPort <= 65535);

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final SshAuthentication authentication;
  final String? hostKeyType;
  final String? hostKeyFingerprint;
  final int remoteCodexPort;

  bool get hasPinnedHostKey =>
      hostKeyType != null && hostKeyFingerprint != null;

  ServerProfile copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    SshAuthentication? authentication,
    String? hostKeyType,
    String? hostKeyFingerprint,
    int? remoteCodexPort,
    bool clearHostKey = false,
  }) {
    return ServerProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authentication: authentication ?? this.authentication,
      hostKeyType: clearHostKey ? null : hostKeyType ?? this.hostKeyType,
      hostKeyFingerprint: clearHostKey
          ? null
          : hostKeyFingerprint ?? this.hostKeyFingerprint,
      remoteCodexPort: remoteCodexPort ?? this.remoteCodexPort,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'authentication': authentication.name,
    'hostKeyType': hostKeyType,
    'hostKeyFingerprint': hostKeyFingerprint,
    'remoteCodexPort': remoteCodexPort,
  };

  factory ServerProfile.fromJson(Map<String, Object?> json) {
    final authenticationName = json['authentication'];
    final authentication = SshAuthentication.values.where(
      (value) => value.name == authenticationName,
    );
    if (authentication.isEmpty) {
      throw const FormatException('Invalid SSH authentication method');
    }

    return ServerProfile(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      host: _requiredString(json, 'host'),
      port: _requiredPort(json, 'port'),
      username: _requiredString(json, 'username'),
      authentication: authentication.single,
      hostKeyType: _optionalString(json, 'hostKeyType'),
      hostKeyFingerprint: _optionalString(json, 'hostKeyFingerprint'),
      remoteCodexPort: _requiredPort(json, 'remoteCodexPort'),
    );
  }

  static String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key must be a non-empty string');
    }
    return value;
  }

  static String? _optionalString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      throw FormatException('$key must be a non-empty string');
    }
    return value;
  }

  static int _requiredPort(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! int || value < 1 || value > 65535) {
      throw FormatException('$key must be between 1 and 65535');
    }
    return value;
  }
}
