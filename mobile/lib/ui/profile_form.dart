import 'package:flutter/material.dart';

import '../app/app_models.dart';
import 'theme/pocket_theme.dart';
import 'widgets/pocket_section_card.dart';

class ProfileFormScreen extends StatefulWidget {
  const ProfileFormScreen({super.key, this.initial});
  final ProfileDraft? initial;

  @override
  State<ProfileFormScreen> createState() => _ProfileFormScreenState();
}

class _ProfileFormScreenState extends State<ProfileFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _key;
  late final TextEditingController _passphrase;
  late final TextEditingController _codexPort;
  late AuthenticationKind _authentication;
  bool _revealPassword = false;
  bool _revealKey = false;
  bool _revealPassphrase = false;

  @override
  void initState() {
    super.initState();
    final value = widget.initial;
    _name = TextEditingController(text: value?.name);
    _host = TextEditingController(text: value?.host);
    _port = TextEditingController(text: '${value?.port ?? 22}');
    _username = TextEditingController(text: value?.username);
    _password = TextEditingController(text: value?.password);
    _key = TextEditingController(text: value?.privateKeyPem);
    _passphrase = TextEditingController(text: value?.privateKeyPassphrase);
    _codexPort = TextEditingController(
      text: '${value?.remoteCodexPort ?? 4500}',
    );
    _authentication = value?.authentication ?? AuthenticationKind.password;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _host,
      _port,
      _username,
      _password,
      _key,
      _passphrase,
      _codexPort,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.initial == null ? '添加服务器' : '编辑服务器')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final allowTwoColumns =
                constraints.maxWidth >= 560 &&
                MediaQuery.textScalerOf(context).scale(1) <= 1.25;
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      PocketSpacing.md,
                      PocketSpacing.sm,
                      PocketSpacing.md,
                      PocketSpacing.xxl,
                    ),
                    children: [
                      PocketSectionCard(
                        icon: Icons.dns_outlined,
                        title: '连接信息',
                        caption: '每台服务器保持独立连接与任务状态',
                        children: [
                          TextFormField(
                            controller: _name,
                            decoration: const InputDecoration(
                              labelText: '名称',
                              hintText: '例如：开发机',
                            ),
                            validator: _required,
                          ),
                          const SizedBox(height: PocketSpacing.sm),
                          if (allowTwoColumns)
                            Row(
                              children: [
                                Expanded(flex: 3, child: _hostField()),
                                const SizedBox(width: PocketSpacing.sm),
                                Expanded(child: _portField()),
                              ],
                            )
                          else ...[
                            _hostField(),
                            const SizedBox(height: PocketSpacing.sm),
                            _portField(),
                          ],
                          const SizedBox(height: PocketSpacing.sm),
                          TextFormField(
                            controller: _username,
                            autocorrect: false,
                            decoration: const InputDecoration(labelText: '用户名'),
                            validator: _required,
                          ),
                        ],
                      ),
                      const SizedBox(height: PocketSpacing.md),
                      PocketSectionCard(
                        icon: Icons.lock_outline_rounded,
                        title: '身份验证',
                        caption: '密码与私钥只写入系统安全存储',
                        children: [
                          SegmentedButton<AuthenticationKind>(
                            expandedInsets: EdgeInsets.zero,
                            segments: const [
                              ButtonSegment(
                                value: AuthenticationKind.password,
                                icon: Icon(Icons.password_rounded),
                                label: Text('密码'),
                              ),
                              ButtonSegment(
                                value: AuthenticationKind.privateKey,
                                icon: Icon(Icons.key_rounded),
                                label: Text('私钥'),
                              ),
                            ],
                            selected: {_authentication},
                            onSelectionChanged: (value) =>
                                setState(() => _authentication = value.first),
                          ),
                          const SizedBox(height: PocketSpacing.sm),
                          if (_authentication == AuthenticationKind.password)
                            TextFormField(
                              controller: _password,
                              obscureText: !_revealPassword,
                              enableSuggestions: false,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText: '密码',
                                suffixIcon: IconButton(
                                  tooltip: _revealPassword ? '隐藏密码' : '显示密码',
                                  onPressed: () => setState(
                                    () => _revealPassword = !_revealPassword,
                                  ),
                                  icon: Icon(
                                    _revealPassword
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                              validator: _required,
                            )
                          else ...[
                            TextFormField(
                              controller: _key,
                              minLines: _revealKey ? 5 : 1,
                              maxLines: _revealKey ? 10 : 1,
                              obscureText: !_revealKey,
                              enableSuggestions: false,
                              autocorrect: false,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(fontFamily: 'monospace'),
                              decoration: InputDecoration(
                                labelText: 'PEM 私钥',
                                alignLabelWithHint: true,
                                hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                                suffixIcon: IconButton(
                                  tooltip: _revealKey ? '隐藏私钥' : '显示私钥',
                                  onPressed: () =>
                                      setState(() => _revealKey = !_revealKey),
                                  icon: Icon(
                                    _revealKey
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                              validator: _required,
                            ),
                            const SizedBox(height: PocketSpacing.sm),
                            TextFormField(
                              controller: _passphrase,
                              obscureText: !_revealPassphrase,
                              enableSuggestions: false,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText: '私钥口令（可选）',
                                suffixIcon: IconButton(
                                  tooltip: _revealPassphrase ? '隐藏口令' : '显示口令',
                                  onPressed: () => setState(
                                    () =>
                                        _revealPassphrase = !_revealPassphrase,
                                  ),
                                  icon: Icon(
                                    _revealPassphrase
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: PocketSpacing.md),
                      PocketSectionCard(
                        icon: Icons.hub_outlined,
                        title: 'Codex',
                        caption: '远端服务仅监听 loopback，通过 SSH tunnel 访问',
                        children: [
                          TextFormField(
                            controller: _codexPort,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '远端 Codex 端口',
                            ),
                            validator: _validPort,
                          ),
                        ],
                      ),
                      const SizedBox(height: PocketSpacing.lg),
                      FilledButton.icon(
                        onPressed: _submit,
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('保存服务器'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _hostField() => TextFormField(
    controller: _host,
    autocorrect: false,
    keyboardType: TextInputType.url,
    decoration: const InputDecoration(labelText: '主机名或 IP'),
    validator: _required,
  );
  Widget _portField() => TextFormField(
    controller: _port,
    keyboardType: TextInputType.number,
    decoration: const InputDecoration(labelText: 'SSH 端口'),
    validator: _validPort,
  );

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '此项不能为空' : null;
  String? _validPort(String? value) {
    final port = int.tryParse(value ?? '');
    return port == null || port < 1 || port > 65535 ? '请输入 1–65535' : null;
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.pop(
      context,
      ProfileDraft(
        id: widget.initial?.id,
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text),
        username: _username.text.trim(),
        authentication: _authentication,
        password: _password.text,
        privateKeyPem: _key.text,
        privateKeyPassphrase: _passphrase.text,
        remoteCodexPort: int.parse(_codexPort.text),
      ),
    );
  }
}
