import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:process_run/shell.dart';
import 'package:wireguard_flutter/model/stats.dart';
import '../wireguard_flutter_platform_interface.dart';

class WireGuardFlutterLinux extends WireGuardFlutterInterface {
  String? name;
  File? configFile;

  VpnStage _stage = VpnStage.noConnection;
  final _stageController = StreamController<VpnStage>.broadcast();
  void _setStage(VpnStage stage) {
    _stage = stage;
    _stageController.add(stage);
  }

  final shell = Shell(runInShell: true, verbose: kDebugMode);

  @override
  Future<void> initialize({required String interfaceName}) async {
    name = interfaceName.replaceAll(' ', '_');
    await refreshStage();
  }

  Future<String> get filePath async {
    final tempDir = await getTemporaryDirectory();
    return '${tempDir.path}${Platform.pathSeparator}$name.conf';
  }

  @override
  Future<void> startVpn({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
  }) async {
    final isAlreadyConnected = await isConnected();
    if (!isAlreadyConnected) {
      _setStage(VpnStage.preparing);
    } else {
      debugPrint('Already connected');
    }

    try {
      configFile = await File(await filePath).create();
      await configFile!.writeAsString(wgQuickConfig);
    } on PathAccessException {
      debugPrint('Denied to write file. Trying to start interface');
      if (isAlreadyConnected) {
        return _setStage(VpnStage.connected);
      }

      try {
        await shell.run('sudo wg-quick up $name');
      } catch (_) {
      } finally {
        _setStage(VpnStage.denied);
      }
    }

    if (!isAlreadyConnected) {
      _setStage(VpnStage.connecting);
      await shell.run('sudo wg-quick up ${configFile?.path ?? await filePath}');
      _setStage(VpnStage.connected);
    }
  }

  @override
  Future<void> stopVpn() async {
    assert(
      (await isConnected()),
      'Bad state: vpn has not been started. Call startVpn',
    );
    _setStage(VpnStage.disconnecting);
    try {
      await shell
          .run('sudo wg-quick down ${configFile?.path ?? (await filePath)}');
    } catch (e) {
      await refreshStage();
      rethrow;
    }
    await refreshStage();
  }

  @override
  Future<VpnStage> stage() async => _stage;

  @override
  Stream<VpnStage> get vpnStageSnapshot => _stageController.stream;

  @override
  Future<void> refreshStage() async {
    if (await isConnected()) {
      _setStage(VpnStage.connected);
    } else if (name == null) {
      _setStage(VpnStage.waitingConnection);
    } else if (configFile == null) {
      _setStage(VpnStage.noConnection);
    } else {
      _setStage(VpnStage.disconnected);
    }
  }

  num _parseTransferData(String data) {
  final units = {
    'B': 1,
    'KiB': 1024,
    'MiB': 1024 * 1024,
    'GiB': 1024 * 1024 * 1024
  };
  final parts = data.split(' ');
  if (parts.length < 2) return 0;
  
  final value = num.tryParse(parts[0]) ?? 0;
  final unit = parts[1];

  return value * (units[unit] ?? 1);
}


  Future<Stats?> getStats() async {
  assert(
    (await isConnected()),
    'Bad state: vpn has not been started. Call startVpn',
  );

  final processResultList = await shell.run('sudo wg show $name');
  final process = processResultList.first;
  final lines = process.outLines;

  if (lines.isEmpty) return null;

  num totalDownload = 0;
  num totalUpload = 0;

  print('Raw wg show output: ${process.outLines}'); // Debug print

  for (var line in lines) {
    if (line.contains('transfer:')) {
      var transferData = line.split(': ')[1].split(', ');
      print('Transfer data: $transferData'); // Debug print

      totalDownload += _parseTransferData(transferData[0].trim());
      totalUpload += _parseTransferData(transferData[1].trim());

      print('Parsed Download: ${_parseTransferData(transferData[0].trim())}'); // Debug print
      print('Parsed Upload: ${_parseTransferData(transferData[1].trim())}'); // Debug print
    }
  }

  print('Parsed stats - Download: $totalDownload, Upload: $totalUpload'); // Debug print

  return Stats(
    totalDownload: totalDownload,
    totalUpload: totalUpload,
    // lastHandshake: lastHandshake, // Assuming lastHandshake is not used
  );
}

}
