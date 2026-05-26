import 'dart:async';

import '../../bin/mock_server.dart' as mock_server;

Future<int> main(List<String> args) {
  // Keep the old example entrypoint as a thin compatibility wrapper.
  return mock_server.main([
    '--dist',
    if (args.isNotEmpty) args[0] else 'dist',
    if (args.length > 1) ...['--port', args[1]],
  ]);
}
