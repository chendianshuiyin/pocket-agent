import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'app/app_services.dart';
import 'ui/pocket_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    SemanticsBinding.instance.ensureSemantics();
  }
  runApp(PocketAgentApp(services: ProductionAppServices()));
}
