import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main.dart';

/// Inline chicklet representing an in-flight audio chunk before text is ready.
/// Displays a pulsing indicator and a 0-100% progress track counting down
/// to the next Whisper partial inference.
class InlineChunkChicklet extends StatelessWidget {
  final ValueNotifier<double>? progress;
  final double? progressValue;
  final bool isSpeaking;

  const InlineChunkChicklet({
    super.key,
    this.progress,
    this.progressValue,
    this.isSpeaking = true,
  }) : assert(progress != null || progressValue != null);

  Widget _buildIndicator(double val) {
    return LinearProgressIndicator(
      value: val.clamp(0.05, 1.0),
      backgroundColor: Colors.white12,
      valueColor: AlwaysStoppedAnimation<Color>(
        isSpeaking ? const Color(0xFF10B981) : const Color(0xFF8B5CF6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isSpeaking
              ? const Color(0xFF10B981).withAlpha(160)
              : const Color(0xFF3B82F6).withAlpha(100),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isSpeaking ? Icons.mic : Icons.mic_none,
            size: 14,
            color: isSpeaking ? const Color(0xFF10B981) : Colors.white38,
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 44,
            height: 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: progress != null
                  ? ValueListenableBuilder<double>(
                      valueListenable: progress!,
                      builder: (context, value, _) => _buildIndicator(value),
                    )
                  : _buildIndicator(progressValue ?? 0.05),
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline active segment for drafting partial text.
/// Uses a soft background highlight tint and an animated bottom accent rail.
class InlineActiveDraftSegment extends StatelessWidget {
  final String text;
  final ValueNotifier<double>? progress;
  final double? progressValue;
  final bool isWorkerBusy;

  const InlineActiveDraftSegment({
    super.key,
    required this.text,
    this.progress,
    this.progressValue,
    this.isWorkerBusy = false,
  }) : assert(progress != null || progressValue != null);

  Widget _buildIndicator(double val) {
    return LinearProgressIndicator(
      value: val.clamp(0.05, 1.0),
      backgroundColor: Colors.white10,
      valueColor: AlwaysStoppedAnimation<Color>(
        isWorkerBusy ? const Color(0xFF3B82F6) : const Color(0xFF8B5CF6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF3B82F6).withAlpha(30),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: const TextStyle(
              fontSize: 16,
              height: 1.4,
              color: Color(0xFF93C5FD),
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 2),
          SizedBox(
            width: 56,
            height: 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(1.5),
              child: progress != null
                  ? ValueListenableBuilder<double>(
                      valueListenable: progress!,
                      builder: (context, val, _) => _buildIndicator(val),
                    )
                  : _buildIndicator(progressValue ?? 0.05),
            ),
          ),
        ],
      ),
    );
  }
}

/// Global progress rail sweeping across the bottom of the transcript during
/// high-accuracy full-stream final pass.
class GlobalFinalPassRail extends StatelessWidget {
  final ValueNotifier<double> progress;

  const GlobalFinalPassRail({
    super.key,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withAlpha(240),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
        border: Border(
          top: BorderSide(color: const Color(0xFF3B82F6).withAlpha(120), width: 1),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.auto_awesome, size: 14, color: Color(0xFF60A5FA)),
                  SizedBox(width: 8),
                  Text(
                    'Running high-accuracy final pass...',
                    style: TextStyle(
                      color: Color(0xFF93C5FD),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (context, val, _) {
                  final pct = (val.clamp(0.0, 1.0) * 100).toInt();
                  return Text(
                    '$pct%',
                    style: const TextStyle(
                      color: Color(0xFF60A5FA),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(2)),
            child: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, val, _) {
                return LinearProgressIndicator(
                  minHeight: 4,
                  value: val.clamp(0.02, 1.0),
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF3B82F6)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Modal bottom sheet presenting timing, latency, and telemetry stats for a tapped chunk.
class ChunkMetadataModal extends StatelessWidget {
  final DictationChunkViewData chunk;

  const ChunkMetadataModal({super.key, required this.chunk});

  static Future<void> show(BuildContext context, DictationChunkViewData chunk) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161922),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ChunkMetadataModal(chunk: chunk),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tLagOk = chunk.tLagSec <= 0.5;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'CHUNK #${chunk.chunkIndex} METRICS',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                  color: Colors.white70,
                  fontFamily: 'monospace',
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: (tLagOk ? const Color(0xFF10B981) : const Color(0xFFEF4444)).withAlpha(40),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: tLagOk ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                    width: 0.8,
                  ),
                ),
                child: Text(
                  tLagOk ? 'PASS (<0.5s)' : 'HIGH LAG',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: tLagOk ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 20, color: Colors.white12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _metricTile('T_lag Latency', '${chunk.tLagSec.toStringAsFixed(2)} s'),
              _metricTile('RTF', chunk.rtf.toStringAsFixed(3)),
              _metricTile('Duration', '${chunk.durationSec.toStringAsFixed(2)} s'),
              _metricTile('Time Range', '${chunk.t0.toStringAsFixed(1)}s - ${chunk.t1.toStringAsFixed(1)}s'),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1117),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Verbatim Chunk Text:',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 14, color: Colors.white60),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Copy Chunk Text',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: chunk.text));
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Copied Chunk #${chunk.chunkIndex} to clipboard'),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SelectableText(
                  chunk.text,
                  style: const TextStyle(
                    fontSize: 15,
                    color: Colors.white,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricTile(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.white38)),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}
