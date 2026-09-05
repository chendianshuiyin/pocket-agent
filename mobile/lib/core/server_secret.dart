class ServerSecret {
  ServerSecret({this.password, this.privateKeyPem, this.privateKeyPassphrase}) {
    if (!_hasText(password) && !_hasText(privateKeyPem)) {
      throw ArgumentError('A password or private key is required');
    }
  }

  final String? password;
  final String? privateKeyPem;
  final String? privateKeyPassphrase;

  bool get hasPassword => _hasText(password);
  bool get hasPrivateKey => _hasText(privateKeyPem);

  static bool _hasText(String? value) => value != null && value.isNotEmpty;
}
