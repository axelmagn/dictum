import 'dart:async';
import 'package:flutter/material.dart';
import 'benchmark_runner.dart';
import 'whisper_ffi.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DictumSpikeApp());
}

class DictumSpikeApp extends StatelessWidget {
  const DictumSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dictum Spike 1b — Phone ASR',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const BenchmarkScreen(),
    );
  }
}

class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key});

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  Map<String, dynamic> _deviceInfo = {};
  String _systemInfo = '';
  int _thermalStatus = -1;
  Map<String, dynamic> _batteryStatus = {};
  Timer? _statusTimer;

  String _selectedModel = 'ggml-small.en-q5_0.bin';
  String _selectedMode = 'C1';
  String _selectedAudio = 'clip8.wav';
  int _selectedThreads = 4;

  bool _isRunning = false;
  String _currentTask = '';
  final List<String> _logs = [];
  String _lastTranscript = '';
  BenchmarkResult? _lastResult;

  final ScrollController _logScrollController = ScrollController();

  final List<String> _models = [
    'ggml-small.en-q5_0.bin',
    'ggml-medium.en-q5_0.bin',
  ];

  final List<String> _modes = ['C1', 'C2', 'C3'];

  final List<String> _audios = ['clip8.wav', 'long30.wav'];

  final List<int> _threadsList = [2, 4, 6, 8];

  @override
  void initState() {
    super.initState();
    _initDevice();
    _startStatusPolling();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _logScrollController.dispose();
    super.dispose();
  }

  void _log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _logs.add('[$timestamp] $message');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _initDevice() async {
    try {
      final info = await BenchmarkRunner.getDeviceInfo();
      final thermal = await BenchmarkRunner.getThermalStatus();
      final battery = await BenchmarkRunner.getBatteryStatus();
      String sysInfo = '';
      try {
        sysInfo = WhisperBindings.instance.getSystemInfo();
      } catch (e) {
        sysInfo = 'Error reading system info: $e';
      }

      setState(() {
        _deviceInfo = info;
        _systemInfo = sysInfo;
        _thermalStatus = thermal;
        _batteryStatus = battery;
      });

      _log('Device: ${info['manufacturer']} ${info['model']} (${info['socModel']})');
      _log('RAM: ${((info['totalRamBytes'] ?? 0) / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB | Cores: ${info['cpuCoreCount']}');
      _log('System info: $sysInfo');
    } catch (e) {
      _log('Device init error: $e');
    }
  }

  void _startStatusPolling() {
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted) return;
      final thermal = await BenchmarkRunner.getThermalStatus();
      final battery = await BenchmarkRunner.getBatteryStatus();
      setState(() {
        _thermalStatus = thermal;
        _batteryStatus = battery;
      });
    });
  }

  String _getBaseStoragePath() {
    final ext = _deviceInfo['externalFilesDir'] as String?;
    if (ext != null && ext.isNotEmpty) {
      return ext;
    }
    return '/sdcard/Android/data/dev.dictum.spike.app/files';
  }

  BenchmarkConfig _createConfig({
    required String modelName,
    required String mode,
    required String audioName,
    required int threads,
    String? runId,
  }) {
    final basePath = _getBaseStoragePath();
    final modelPath = '$basePath/models/$modelName';
    final vadPath = '$basePath/models/ggml-silero-v6.2.0.bin';
    final audioPath = '$basePath/audio/$audioName';
    final outDir = '$basePath/out';

    final shortModel = modelName.replaceAll('ggml-', '').replaceAll('.bin', '');

    return BenchmarkConfig(
      modelPath: modelPath,
      modelName: shortModel,
      vadModelPath: vadPath,
      audioPath: audioPath,
      audioName: audioName,
      mode: mode,
      threads: threads,
      outDir: outDir,
      runId: runId,
    );
  }

  Future<void> _runSingleBenchmark() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _currentTask = 'Running $_selectedModel × $_selectedMode';
    });

    try {
      final config = _createConfig(
        modelName: _selectedModel,
        mode: _selectedMode,
        audioName: _selectedAudio,
        threads: _selectedThreads,
      );

      final result = await BenchmarkRunner.runBenchmark(config, onLog: _log);
      setState(() {
        _lastResult = result;
        _lastTranscript = result.toTranscriptText();
      });
    } catch (e, st) {
      _log('RUN ERROR: $e\n$st');
    } finally {
      setState(() {
        _isRunning = false;
        _currentTask = '';
      });
    }
  }

  Future<void> _runThreadSweep() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _currentTask = 'Sweeping threads (2, 4, 6, 8)';
    });

    _log('=== STARTING THREAD SWEEP (small.en-q5_0 × C1 × clip8) ===');
    final sweepResults = <int, double>{};

    try {
      for (final th in _threadsList) {
        _log('--- Testing $th threads ---');
        final config = _createConfig(
          modelName: 'ggml-small.en-q5_0.bin',
          mode: 'C1',
          audioName: 'clip8.wav',
          threads: th,
          runId: 'sweep__small.en-q5_0__C1__th${th}__clip8',
        );

        final result = await BenchmarkRunner.runBenchmark(config, onLog: _log);
        sweepResults[th] = result.rtf;
        _log('Result for $th threads: RTF = ${result.rtf.toStringAsFixed(3)}, Wall = ${result.transcribeWallTimeMs}ms');
      }

      int bestThreads = _threadsList.first;
      double minRtf = sweepResults[bestThreads]!;
      sweepResults.forEach((th, rtf) {
        if (rtf < minRtf) {
          minRtf = rtf;
          bestThreads = th;
        }
      });

      _log('=== THREAD SWEEP COMPLETE ===');
      _log('Fastest thread count: $bestThreads (RTF ${minRtf.toStringAsFixed(3)})');
      setState(() {
        _selectedThreads = bestThreads;
      });
    } catch (e, st) {
      _log('SWEEP ERROR: $e\n$st');
    } finally {
      setState(() {
        _isRunning = false;
        _currentTask = '';
      });
    }
  }

  Future<void> _runAllMatrix() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _currentTask = 'Running Full Benchmark Suite';
    });

    _log('========================================');
    _log('STARTING FULL BENCHMARK MATRIX');
    _log('========================================');

    try {
      // 1. Thread Sweep
      _log('\n--- Step 1: Thread Sweep ---');
      int optimalThreads = _selectedThreads;
      for (final th in [2, 4, 6, 8]) {
        final config = _createConfig(
          modelName: 'ggml-small.en-q5_0.bin',
          mode: 'C1',
          audioName: 'clip8.wav',
          threads: th,
          runId: 'sweep__small.en-q5_0__C1__th${th}__clip8',
        );
        final res = await BenchmarkRunner.runBenchmark(config, onLog: _log);
        if (th == 2 || res.rtf < 0.2) {
          // just track
        }
      }

      optimalThreads = _selectedThreads; // Use selected or optimal
      _log('Using $optimalThreads threads for matrix runs.');

      // 2. small.en-q5_0 on clip8 (C1, C2, C3)
      for (final m in ['C1', 'C2', 'C3']) {
        _log('\n--- small.en-q5_0 × $m × clip8 ---');
        final config = _createConfig(
          modelName: 'ggml-small.en-q5_0.bin',
          mode: m,
          audioName: 'clip8.wav',
          threads: optimalThreads,
          runId: 'small.en-q5_0__${m}__clip8',
        );
        final res = await BenchmarkRunner.runBenchmark(config, onLog: _log);
        setState(() {
          _lastResult = res;
          _lastTranscript = res.toTranscriptText();
        });
      }

      // 3. small.en-q5_0 on long30 (C2) - the key sustained benchmark
      _log('\n--- small.en-q5_0 × C2 × long30 (SUSTAINED LOAD TEST) ---');
      final longConfig = _createConfig(
        modelName: 'ggml-small.en-q5_0.bin',
        mode: 'C2',
        audioName: 'long30.wav',
        threads: optimalThreads,
        runId: 'small.en-q5_0__C2__long30',
      );
      final longRes = await BenchmarkRunner.runBenchmark(longConfig, onLog: _log);
      setState(() {
        _lastResult = longRes;
        _lastTranscript = longRes.toTranscriptText();
      });

      // 4. medium.en-q5_0 on clip8 (C1, C2, C3)
      double mediumC1Rtf = 999.0;
      for (final m in ['C1', 'C2', 'C3']) {
        _log('\n--- medium.en-q5_0 × $m × clip8 ---');
        final config = _createConfig(
          modelName: 'ggml-medium.en-q5_0.bin',
          mode: m,
          audioName: 'clip8.wav',
          threads: optimalThreads,
          runId: 'medium.en-q5_0__${m}__clip8',
        );
        final res = await BenchmarkRunner.runBenchmark(config, onLog: _log);
        if (m == 'C1') mediumC1Rtf = res.rtf;
        setState(() {
          _lastResult = res;
          _lastTranscript = res.toTranscriptText();
        });
      }

      // 5. medium.en-q5_0 on long30 (C2) if clip8 RTF <= 1.0
      if (mediumC1Rtf <= 1.0) {
        _log('\n--- medium.en-q5_0 × C2 × long30 (clip8 RTF <= 1.0) ---');
        final medLongConfig = _createConfig(
          modelName: 'ggml-medium.en-q5_0.bin',
          mode: 'C2',
          audioName: 'long30.wav',
          threads: optimalThreads,
          runId: 'medium.en-q5_0__C2__long30',
        );
        final medLongRes = await BenchmarkRunner.runBenchmark(medLongConfig, onLog: _log);
        setState(() {
          _lastResult = medLongRes;
          _lastTranscript = medLongRes.toTranscriptText();
        });
      } else {
        _log('Skipping medium.en-q5_0 long30: clip8 RTF ($mediumC1Rtf) > 1.0');
      }

      _log('========================================');
      _log('ALL MATRIX RUNS FINISHED SUCCESSFULLY');
      _log('========================================');
    } catch (e, st) {
      _log('MATRIX RUN ERROR: $e\n$st');
    } finally {
      setState(() {
        _isRunning = false;
        _currentTask = '';
      });
    }
  }

  String _formatThermal(int status) {
    switch (status) {
      case 0: return 'NONE (0)';
      case 1: return 'LIGHT (1)';
      case 2: return 'MODERATE (2)';
      case 3: return 'SEVERE (3)';
      case 4: return 'CRITICAL (4)';
      case 5: return 'EMERGENCY (5)';
      case 6: return 'SHUTDOWN (6)';
      default: return 'UNKNOWN ($status)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final batteryPct = _batteryStatus['percent'] ?? -1;
    final isCharging = _batteryStatus['isCharging'] == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dictum Spike 1b — Phone ASR'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isRunning ? null : _initDevice,
            tooltip: 'Refresh Info',
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Device & Status Card
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_deviceInfo['manufacturer'] ?? ''} ${_deviceInfo['model'] ?? 'Device'}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text('SoC: ${_deviceInfo['socModel'] ?? 'Unknown'} | Cores: ${_deviceInfo['cpuCoreCount'] ?? '?'} | Android: ${_deviceInfo['androidRelease'] ?? '?'} (API ${_deviceInfo['sdkInt'] ?? '?'})'),
                    Text('Total RAM: ${((_deviceInfo['totalRamBytes'] ?? 0) / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB'),
                    const Divider(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text('Thermal: ${_formatThermal(_thermalStatus)}',
                            style: TextStyle(
                              color: _thermalStatus >= 3 ? Colors.red : Colors.green.shade800,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'Battery: $batteryPct% ${isCharging ? "⚡" : ""}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'SIMD: $_systemInfo',
                      style: const TextStyle(fontSize: 11, color: Colors.black87),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Dropdown Controls Card
            Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedModel,
                            decoration: const InputDecoration(labelText: 'Model', isDense: true),
                            items: _models.map((m) => DropdownMenuItem(value: m, child: Text(m.replaceAll('ggml-', '').replaceAll('.bin', '')))).toList(),
                            onChanged: _isRunning ? null : (v) => setState(() => _selectedModel = v!),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedMode,
                            decoration: const InputDecoration(labelText: 'Mode', isDense: true),
                            items: _modes.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                            onChanged: _isRunning ? null : (v) => setState(() => _selectedMode = v!),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _selectedAudio,
                            decoration: const InputDecoration(labelText: 'Audio', isDense: true),
                            items: _audios.map((a) => DropdownMenuItem(value: a, child: Text(a))).toList(),
                            onChanged: _isRunning ? null : (v) => setState(() => _selectedAudio = v!),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: _selectedThreads,
                            decoration: const InputDecoration(labelText: 'Threads', isDense: true),
                            items: _threadsList.map((t) => DropdownMenuItem(value: t, child: Text('$t threads'))).toList(),
                            onChanged: _isRunning ? null : (v) => setState(() => _selectedThreads = v!),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isRunning ? null : _runSingleBenchmark,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Run Selected'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isRunning ? null : _runThreadSweep,
                            icon: const Icon(Icons.speed),
                            label: const Text('Sweep Threads'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _isRunning ? null : _runAllMatrix,
                        icon: const Icon(Icons.playlist_play),
                        label: const Text('Run All Benchmarks (Matrix)'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.deepPurple,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (_isRunning) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(),
              const SizedBox(height: 4),
              Text(
                _currentTask,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple),
              ),
            ],

            const SizedBox(height: 8),

            // Live Log Console
            Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Live Execution Log', style: TextStyle(fontWeight: FontWeight.bold)),
                        IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => setState(() => _logs.clear()),
                          tooltip: 'Clear log',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    const Divider(height: 8),
                    Container(
                      height: 180,
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: ListView.builder(
                        controller: _logScrollController,
                        itemCount: _logs.length,
                        itemBuilder: (context, idx) {
                          return Text(
                            _logs[idx],
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Last Transcript
            Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Last Transcript ${_lastResult != null ? "(${_lastResult!.runId}, RTF: ${_lastResult!.rtf.toStringAsFixed(3)})" : ""}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const Divider(height: 12),
                    Container(
                      height: 160,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          _lastTranscript.isEmpty ? '(No transcript yet)' : _lastTranscript,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
