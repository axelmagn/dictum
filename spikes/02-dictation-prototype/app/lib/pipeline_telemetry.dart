import 'package:flutter/material.dart';

import 'whisper_worker.dart';

/// Lightweight telemetry controller using ValueNotifiers to isolate high-frequency
/// (31 Hz) pipeline ticks from full-tree widget rebuilds.
class PipelineTelemetryController {
  final ValueNotifier<double> micRms = ValueNotifier<double>(0.0);
  final ValueNotifier<double> speechProb = ValueNotifier<double>(0.0);
  final ValueNotifier<double> pauseProgress = ValueNotifier<double>(0.0);
  final ValueNotifier<int> pauseFrames = ValueNotifier<int>(0);
  final ValueNotifier<int> targetPauseFrames = ValueNotifier<int>(16);
  final ValueNotifier<bool> inSpeech = ValueNotifier<bool>(false);
  final ValueNotifier<double> partialProgress = ValueNotifier<double>(0.0);
  final ValueNotifier<int> partialElapsedMs = ValueNotifier<int>(0);
  final ValueNotifier<WhisperWorkerStatus> workerStatus =
      ValueNotifier<WhisperWorkerStatus>(WhisperWorkerStatus.idle);
  final ValueNotifier<double> finalPassProgress = ValueNotifier<double>(0.0);
  final ValueNotifier<int> frameCount = ValueNotifier<int>(0);

  void reset() {
    micRms.value = 0.0;
    speechProb.value = 0.0;
    pauseProgress.value = 0.0;
    pauseFrames.value = 0;
    inSpeech.value = false;
    partialProgress.value = 0.0;
    partialElapsedMs.value = 0;
    workerStatus.value = WhisperWorkerStatus.idle;
    finalPassProgress.value = 0.0;
    frameCount.value = 0;
  }

  void updateFrame({
    required double rms,
    required double prob,
    required int consecutivePause,
    required int maxPause,
    required bool isSpeaking,
    required int elapsedSincePartialMs,
    required int partialIntervalMs,
  }) {
    frameCount.value++;
    micRms.value = (rms * 4.0).clamp(0.0, 1.0);
    speechProb.value = prob.clamp(0.0, 1.0);
    pauseFrames.value = consecutivePause;
    targetPauseFrames.value = maxPause;
    pauseProgress.value = maxPause > 0
        ? (consecutivePause / maxPause).clamp(0.0, 1.0)
        : 0.0;
    inSpeech.value = isSpeaking;

    if (partialIntervalMs > 0 && elapsedSincePartialMs >= 0) {
      partialElapsedMs.value = elapsedSincePartialMs.clamp(0, partialIntervalMs);
      partialProgress.value =
          (elapsedSincePartialMs / partialIntervalMs).clamp(0.0, 1.0);
    } else {
      partialElapsedMs.value = 0;
      partialProgress.value = 0.0;
    }
  }

  void updateWorker(WhisperWorkerStatus status) {
    workerStatus.value = status;
    if (status.isFinalPass && status.progress > 0) {
      finalPassProgress.value = status.progress;
    }
  }

  void dispose() {
    micRms.dispose();
    speechProb.dispose();
    pauseProgress.dispose();
    pauseFrames.dispose();
    targetPauseFrames.dispose();
    inSpeech.dispose();
    partialProgress.dispose();
    partialElapsedMs.dispose();
    workerStatus.dispose();
    finalPassProgress.dispose();
    frameCount.dispose();
  }
}

/// A compact, high-density telemetry deck that exposes each streaming stage's
/// refresh rate, state, and buffers without lagging the main UI.
class PipelineTelemetryDeck extends StatelessWidget {
  final PipelineTelemetryController controller;

  const PipelineTelemetryDeck({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161922),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF262A38), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDeckHeader(),
          const SizedBox(height: 10),
          _buildStage1Mic(),
          const SizedBox(height: 8),
          _buildStage2Vad(),
          const SizedBox(height: 8),
          _buildStage3Partial(),
          const SizedBox(height: 8),
          _buildStage4Worker(),
        ],
      ),
    );
  }

  Widget _buildDeckHeader() {
    return ValueListenableBuilder<int>(
      valueListenable: controller.frameCount,
      builder: (context, frames, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(Icons.insights, size: 14, color: Color(0xFF3B82F6)),
                SizedBox(width: 6),
                Text(
                  'PIPELINE TELEMETRY',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                    color: Colors.white70,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            Text(
              '${(frames * 0.032).toStringAsFixed(1)}s stream · frame #$frames',
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white38,
                fontFamily: 'monospace',
              ),
            ),
          ],
        );
      },
    );
  }

  // --- STAGE 1: MIC INGESTION ---
  Widget _buildStage1Mic() {
    return ValueListenableBuilder<double>(
      valueListenable: controller.micRms,
      builder: (context, rms, _) {
        return _buildStageRow(
          title: '1. MIC IN',
          cadenceBadge: '31.2 Hz · 32ms',
          rightLabel: '${(rms * 100).toStringAsFixed(0)}% RMS',
          progress: rms,
          barColor: rms > 0.8
              ? const Color(0xFFEF4444)
              : (rms > 0.2 ? const Color(0xFF10B981) : const Color(0xFF3B82F6)),
        );
      },
    );
  }

  // --- STAGE 2: SILERO VAD ---
  Widget _buildStage2Vad() {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.inSpeech,
      builder: (context, inSpeech, _) {
        return ValueListenableBuilder<double>(
          valueListenable: controller.speechProb,
          builder: (context, prob, _) {
            return ValueListenableBuilder<double>(
              valueListenable: controller.pauseProgress,
              builder: (context, pauseProg, _) {
                final probColor = prob >= 0.5
                    ? const Color(0xFF10B981)
                    : (prob >= 0.35 ? Colors.amber : Colors.white24);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Text(
                              '2. SILERO VAD',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white70,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(width: 6),
                            _badge(
                              '31.2 Hz',
                              const Color(0xFF1E293B),
                              Colors.white60,
                            ),
                            const SizedBox(width: 4),
                            _badge(
                              inSpeech ? 'SPEECH' : 'SILENCE',
                              inSpeech
                                  ? const Color(0xFF10B981).withAlpha(50)
                                  : Colors.white10,
                              inSpeech ? const Color(0xFF10B981) : Colors.white38,
                            ),
                          ],
                        ),
                        Text(
                          'P=${prob.toStringAsFixed(2)} · Pause: ${(pauseProg * 16).toInt()}/16f',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white60,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        // Speech Probability Bar
                        Expanded(
                          flex: 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: prob,
                              minHeight: 4,
                              backgroundColor: Colors.white10,
                              valueColor: AlwaysStoppedAnimation(probColor),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Pause Closure Countdown Bar
                        Expanded(
                          flex: 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: pauseProg,
                              minHeight: 4,
                              backgroundColor: Colors.white10,
                              valueColor: AlwaysStoppedAnimation(
                                pauseProg > 0.8
                                    ? Colors.amber
                                    : const Color(0xFF3B82F6),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  // --- STAGE 3: PARTIAL DRAFTER ---
  Widget _buildStage3Partial() {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.inSpeech,
      builder: (context, inSpeech, _) {
        return ValueListenableBuilder<double>(
          valueListenable: controller.partialProgress,
          builder: (context, progress, _) {
            return ValueListenableBuilder<int>(
              valueListenable: controller.partialElapsedMs,
              builder: (context, elapsed, _) {
                return _buildStageRow(
                  title: '3. PARTIAL DRAFTER',
                  cadenceBadge: '1.0 Hz · 1000ms',
                  rightLabel: inSpeech ? '${elapsed}ms / 1000ms' : 'PAUSED',
                  progress: inSpeech ? progress : 0.0,
                  barColor: const Color(0xFF8B5CF6),
                );
              },
            );
          },
        );
      },
    );
  }

  // --- STAGE 4: WHISPER WORKER ---
  Widget _buildStage4Worker() {
    return ValueListenableBuilder<WhisperWorkerStatus>(
      valueListenable: controller.workerStatus,
      builder: (context, status, _) {
        final isBusy = status.isBusy;
        final hasQueue = status.pendingCount > 0;
        final activeText = isBusy
            ? '${status.isPartial ? "Partial" : "Final"} #${status.activeChunkIndex ?? 0}'
            : 'IDLE';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Text(
                      '4. WHISPER INFER',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.white70,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(width: 6),
                    _badge(
                      isBusy ? 'ACTIVE' : 'IDLE',
                      isBusy
                          ? const Color(0xFF3B82F6).withAlpha(50)
                          : Colors.white10,
                      isBusy ? const Color(0xFF3B82F6) : Colors.white38,
                    ),
                    if (hasQueue) ...[
                      const SizedBox(width: 4),
                      _badge(
                        'Q: ${status.pendingCount}',
                        Colors.amber.withAlpha(50),
                        Colors.amber,
                      ),
                    ],
                  ],
                ),
                Text(
                  '$activeText · ctx: ${status.audioCtx}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white60,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: isBusy
                  ? const LinearProgressIndicator(
                      minHeight: 4,
                      backgroundColor: Colors.white10,
                      valueColor: AlwaysStoppedAnimation(Color(0xFF3B82F6)),
                    )
                  : const LinearProgressIndicator(
                      value: 0.0,
                      minHeight: 4,
                      backgroundColor: Colors.white10,
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStageRow({
    required String title,
    required String cadenceBadge,
    required String rightLabel,
    required double progress,
    required Color barColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white70,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 6),
                _badge(cadenceBadge, const Color(0xFF1E293B), Colors.white60),
              ],
            ),
            Text(
              rightLabel,
              style: const TextStyle(
                fontSize: 10,
                color: Colors.white60,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 4,
            backgroundColor: Colors.white10,
            valueColor: AlwaysStoppedAnimation(barColor),
          ),
        ),
      ],
    );
  }

  Widget _badge(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.bold,
          color: fg,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
