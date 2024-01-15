import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

class MediaKitPlayer extends AudioPlayerPlatform {
  late final Player _player;
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();
  Future<void> get isReady => _readyCompleter.future;

  static final _logger = Logger('MediaKitPlayer');

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;
  int _currentIndex = 0;

  MediaKitPlayer(super.id) {
    _player = Player(
        configuration: PlayerConfiguration(
      protocolWhitelist: JustAudioMediaKit.protocolWhitelist,
      title: JustAudioMediaKit.title,
      bufferSize: JustAudioMediaKit.bufferSize,
      logLevel: JustAudioMediaKit.mpvLogLevel,
      ready: () => _readyCompleter.complete(),
    ));

    // store subscriptions to cancel later
    _streamSubscriptions = [
      _player.stream.duration.listen((duration) {
        _processingState = ProcessingStateMessage.ready;
        _updatePlaybackEvent(duration: duration);
      }),
      _player.stream.position.listen((position) {
        _position = position;
        _updatePlaybackEvent();
      }),
      _player.stream.buffering.listen((isBuffering) {
        _logger.fine('isBuffering: $isBuffering');
        _processingState = isBuffering
            ? ProcessingStateMessage.buffering
            : ProcessingStateMessage.ready;
        _updatePlaybackEvent();
      }),
      _player.stream.buffer.listen((buffer) {
        _bufferedPosition = buffer;
        _updatePlaybackEvent();
      }),
      _player.stream.playing.listen((playing) {
        _processingState = ProcessingStateMessage.ready;
        _dataController.add(PlayerDataMessage(playing: playing));
        _updatePlaybackEvent();
      }),
      _player.stream.volume.listen((volume) {
        _dataController.add(PlayerDataMessage(volume: volume / 100.0));
      }),
      _player.stream.completed.listen((completed) {
        _processingState = completed
            ? ProcessingStateMessage.completed
            : ProcessingStateMessage.ready;
        _updatePlaybackEvent();
      }),
      _player.stream.error.listen((error) {
        _processingState = ProcessingStateMessage.idle;
        _updatePlaybackEvent();
        _logger.severe('ERROR OCCURRED: $error');
      }),
      _player.stream.playlist.listen((playlist) {
        _currentIndex = playlist.index;
        _updatePlaybackEvent();
      }),
      _player.stream.pitch.listen((pitch) {
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        print("MPV: [${event.level}] ${event.prefix}: ${event.text}");
      }),
    ];
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  void _updatePlaybackEvent(
      {Duration? duration, IcyMetadataMessage? icyMetadata}) {
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _bufferedPosition,
      duration: duration,
      icyMetadata: icyMetadata,
      currentIndex: _currentIndex,
      androidAudioSessionId: null,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.fine('load(${request.toMap()})');
    _currentIndex = request.initialIndex ?? 0;
    _bufferedPosition = Duration.zero;
    _position = Duration.zero;
    _player.pause();
    return LoadResponse(duration: _player.state.duration);
  }

  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    if (audioSource is UriAudioSourceMessage) {
      String url = audioSource.uri;
      if (!url.contains("http")) {
        url = "file://$url";
      }
      return Media(url, httpHeaders: audioSource.headers);
    } else {
      throw UnsupportedError(
          '${audioSource.runtimeType} is currently not supported');
    }
  }

  @override
  Future<PlayResponse> play(PlayRequest request) {
    return _player.play().then((_) => PlayResponse());
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) {
    return _player.pause().then((_) => PauseResponse());
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) {
    return _player
        .setVolume(request.volume * 100.0)
        .then((value) => SetVolumeResponse());
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) {
    return _player.setRate(request.speed).then((_) => SetSpeedResponse());
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) =>
      _player.setPitch(request.pitch).then((_) => SetPitchResponse());

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) => _player
      .setPlaylistMode(const {
        LoopModeMessage.off: PlaylistMode.none,
        LoopModeMessage.one: PlaylistMode.single,
        LoopModeMessage.all: PlaylistMode.loop,
      }[request.loopMode]!)
      .then((_) => SetLoopModeResponse());

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) =>
      _player
          .setShuffle(request.shuffleMode == ShuffleModeMessage.all)
          .then((_) => SetShuffleModeResponse());

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _logger.finest('seek(${request.toMap()})');
    if (request.index != null) {
      await _player.jump(request.index!);
    }

    if (request.position != null) {
      _position = request.position!;
      await _player.seek(request.position!);
    } else {
      _position = Duration.zero;
    }

    // reset position on seek
    _updatePlaybackEvent();
    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    await _player.open(_convertAudioSourceIntoMediaKit(request.children[0]));
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    try {
      await _player.remove(0);
    // ignore: empty_catches
    } catch (e) {}

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
          ConcatenatingMoveRequest request) =>
      _player
          .move(request.currentIndex, request.newIndex)
          .then((_) => ConcatenatingMoveResponse());

  Future<void> release() async {
    _logger.info('releasing player resources');
    await _player.dispose();

    // cancel all stream subscriptions
    for (final StreamSubscription subscription in _streamSubscriptions) {
      await subscription.cancel();
    }
  }
}
