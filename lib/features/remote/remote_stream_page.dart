import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/files/file_tools.dart';
import '../../services/remote/nex_gallery_client.dart';
import '../common/file_preview.dart';

/// A session-only loopback proxy keeps credentials and certificate trust out of
/// the native player's URL, while forwarding byte ranges over the pinned TLS connection.
class RemoteStreamPage extends StatefulWidget {
  const RemoteStreamPage({
    required this.client,
    required this.entry,
    this.quality,
    this.pollInterval = const Duration(seconds: 1),
    super.key,
  });
  final NexGalleryRemoteClient client;
  final RemoteEntry entry;

  /// Streams the PC's smaller copy at this height, for mobile data.
  final int? quality;
  final Duration pollInterval;
  @override
  State<RemoteStreamPage> createState() => _RemoteStreamPageState();
}

class _RemoteStreamPageState extends State<RemoteStreamPage> {
  HttpServer? _server;
  Uri? _uri;
  String? _error;
  int? _quality;
  ProxyProgress? _preparing;
  Timer? _poll;
  final _secret = uniqueId();
  @override
  void initState() {
    super.initState();
    _quality = widget.quality;
    _quality == null ? _start() : _prepare();
  }

  /// Waits while the PC converts the video, then plays the copy.
  Future<void> _prepare() async {
    final quality = _quality;
    if (quality == null || !mounted) return;
    try {
      final progress = await widget.client.proxyStatus(widget.entry, quality);
      if (!mounted || _quality == null) return;
      if (progress.ready) {
        setState(() => _preparing = null);
        await _start();
      } else if (progress.failed) {
        _playOriginal(progress.error ?? 'The PC could not convert this video.');
      } else {
        setState(() => _preparing = progress);
        _poll = Timer(widget.pollInterval, _prepare);
      }
    } on RemoteApiException catch (error) {
      _playOriginal(error.message);
    } on Object {
      _playOriginal('The smaller copy is unavailable.');
    }
  }

  void _playOriginal([String? reason]) {
    _poll?.cancel();
    if (!mounted) return;
    setState(() {
      _quality = null;
      _preparing = null;
    });
    if (reason != null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('$reason Playing the original.')));
    }
    _start();
  }

  Future<void> _start() async {
    if (_server != null) return;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (!mounted) {
        await server.close(force: true);
        return;
      }
      _server = server;
      final quality = _quality;
      server.listen((request) async {
        try {
          if (request.uri.path != '/$_secret' ||
              (request.method != 'GET' && request.method != 'HEAD')) {
            request.response.statusCode = 404;
            await request.response.close();
            return;
          }
          final response = await widget.client.readStream(
            widget.entry,
            range: request.headers.value(HttpHeaders.rangeHeader),
            method: request.method,
            quality: quality,
          );
          request.response.statusCode = response.statusCode;
          for (final header in [
            HttpHeaders.contentTypeHeader,
            HttpHeaders.contentLengthHeader,
            HttpHeaders.contentRangeHeader,
            HttpHeaders.acceptRangesHeader,
          ]) {
            final value = response.headers.value(header);
            if (value != null) request.response.headers.set(header, value);
          }
          await request.response.addStream(response);
          await request.response.close();
        } catch (_) {
          try {
            request.response.statusCode = 502;
            await request.response.close();
          } on Object {
            /* player disconnected */
          }
        }
      });
      setState(
        () => _uri = Uri.parse('http://127.0.0.1:${server.port}/$_secret'),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_server?.close(force: true) ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_uri != null) {
      return FilePreview(
        name: widget.entry.name,
        videoUri: _uri,
        isVideo: true,
      );
    }
    final preparing = _preparing;
    return Scaffold(
      appBar: AppBar(title: Text(widget.entry.name)),
      body: Center(
        child: _error != null
            ? Text(_error!)
            : preparing == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Your PC is making a ${_quality}p copy for mobile data',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value:
                          preparing.status == 'preparing' &&
                              preparing.progress > 0
                          ? preparing.progress
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      preparing.status == 'queued'
                          ? 'Waiting for another video to finish'
                          : '${(preparing.progress * 100).round()}%',
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _playOriginal,
                      child: const Text('Play the original instead'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
