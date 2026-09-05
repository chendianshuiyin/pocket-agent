import 'package:pocket_agent/codex/codex.dart';

const liveApprovalMarker = '__POCKET_APPROVAL_MARKER__';
const liveApprovalCommand = "printf '$liveApprovalMarker'";
const liveApprovalCommands = <String>{
  liveApprovalCommand,
  "/bin/bash -c \"$liveApprovalCommand\"",
  "/bin/bash -lc \"$liveApprovalCommand\"",
  "/bin/sh -c \"$liveApprovalCommand\"",
};

String? validateLiveCommandApproval(
  ServerRequest request, {
  required String threadId,
  required String turnId,
  required String cwd,
}) {
  if (request.method != 'item/commandExecution/requestApproval') {
    return 'unexpected request method';
  }
  if (request.threadId != threadId || request.turnId != turnId) {
    return 'request scope mismatch';
  }
  if (request.itemId == null || request.itemId!.isEmpty) {
    return 'missing item id';
  }
  if (request.params['cwd'] != cwd) return 'cwd mismatch';
  if (!liveApprovalCommands.contains(request.params['command'])) {
    return 'command is not allowlisted';
  }
  if (request.params['networkApprovalContext'] != null ||
      request.params['additionalPermissions'] != null ||
      request.params['proposedNetworkPolicyAmendments'] != null) {
    return 'extra permissions are not allowed';
  }
  final kind = request.params['kind'];
  if (kind != null && kind != 'command') return 'unexpected approval kind';
  final decisions = request.params['availableDecisions'];
  if (decisions is List && !decisions.contains('accept')) {
    return 'accept decision is unavailable';
  }
  return null;
}
