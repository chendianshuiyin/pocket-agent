import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_agent/ssh/shell_command.dart';

void main() {
  test('quotes every shell argument including embedded apostrophes', () {
    expect(
      buildShellCommand('tmux', ['new-session', "a'b", r'$HOME; rm -rf x']),
      "tmux 'new-session' 'a'\"'\"'b' '\$HOME; rm -rf x'",
    );
  });

  test('rejects executable injection and NUL arguments', () {
    expect(() => buildShellCommand('tmux;id', const []), throwsArgumentError);
    expect(() => quoteShellArgument('bad\u0000value'), throwsArgumentError);
  });

  test('only accepts bounded Pocket Agent tmux identifiers', () {
    expect(validatePocketSessionId('alpha_1-beta'), 'alpha_1-beta');
    expect(() => validatePocketSessionId('../other'), throwsArgumentError);
    expect(
      () => validatePocketSessionId(List.filled(49, 'a').join()),
      throwsArgumentError,
    );
  });
}
