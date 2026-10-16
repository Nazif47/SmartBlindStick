import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui'; // For ImageFilter

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:mjpeg_stream/mjpeg_stream.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

// REMOVED: ONNX imports
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VisionAssistApp());
}

class VisionAssistApp extends StatelessWidget {
  const VisionAssistApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VisionAssist',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'Segoe UI',
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF020617), // Slate 950
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6366F1), // Indigo
          brightness: Brightness.dark,
          surface: const Color(0xFF0F172A), // Slate 900
          background: const Color(0xFF020617),
          primary: const Color(0xFF6366F1),
          secondary: const Color(0xFFEC4899),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

enum SystemState { online, preparingToSleep, shutDown }

class Telemetry {
  final double lat;
  final double lon;
  final double headDist;
  final double groundDist;
  final bool obstacle;
  final String aiText;
  final bool stickAngleCorrect;
  final bool gsmConnected;
  final bool nrfFallbackActive;
  final SystemState systemStatus;

  Telemetry({
    required this.lat,
    required this.lon,
    required this.headDist,
    required this.groundDist,
    required this.obstacle,
    required this.aiText,
    required this.stickAngleCorrect,
    required this.gsmConnected,
    required this.nrfFallbackActive,
    required this.systemStatus,
  });

  Telemetry copyWith({
    double? lat,
    double? lon,
    double? headDist,
    double? groundDist,
    bool? obstacle,
    String? aiText,
    bool? stickAngleCorrect,
    bool? gsmConnected,
    bool? nrfFallbackActive,
    SystemState? systemStatus,
  }) {
    return Telemetry(
      lat: lat ?? this.lat,
      lon: lon ?? this.lon,
      headDist: headDist ?? this.headDist,
      groundDist: groundDist ?? this.groundDist,
      obstacle: obstacle ?? this.obstacle,
      aiText: aiText ?? this.aiText,
      stickAngleCorrect: stickAngleCorrect ?? this.stickAngleCorrect,
      gsmConnected: gsmConnected ?? this.gsmConnected,
      nrfFallbackActive: nrfFallbackActive ?? this.nrfFallbackActive,
      systemStatus: systemStatus ?? this.systemStatus,
    );
  }
}

Future<void> _openInGoogleMaps(double lat, double lon) async {
  final geoUri = Uri.parse('geo:$lat,$lon?z=16');
  if (await canLaunchUrl(geoUri)) {
    await launchUrl(geoUri, mode: LaunchMode.externalApplication);
  } else {
    final webUri = Uri.https(
      'www.google.com',
      '/maps/search/',
      {'api': '1', 'query': '$lat,$lon'},
    );
    if (!await launchUrl(webUri, mode: LaunchMode.externalApplication)) {
      debugPrint('Could not open Google Maps: $webUri');
    }
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // CONFIGURATION
  // Note: Ensure your ESP32-CAM is on this static IP or use mDNS
  static const String _espStreamUrl = 'http://192.168.4.1:81/stream'; // Default AP IP
  static const String _espCaptureUrl = 'http://192.168.4.1/capture';
  
  // Pass via --dart-define=GEMINI_API_KEY=your_key_here
  static const _apiKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: 'YOUR_GEMINI_API_KEY');

  final Random _rng = Random();
  late Telemetry _data;
  Timer? _timer;
  final FlutterTts _tts = FlutterTts();
  bool _audioBusy = false;
  bool _aiBusy = false;
  final List<String> _alerts = [];
  bool _shutdownCountdownActive = false;

  late GenerativeModel _geminiModel;

  // Bluetooth & Sensors
  BluetoothConnection? _connection;
  String _btStatus = "Disconnected";
  String _btBuffer = ""; // Added buffer for fragmented packets

  // Phone GPS
  Position? _lastPhonePosition;
  StreamSubscription<Position>? _posSub;

  @override
  void initState() {
    super.initState();
    _geminiModel = GenerativeModel(model: 'gemini-1.5-flash-latest', apiKey: _apiKey);

    _data = Telemetry(
      lat: 0.0,
      lon: 0.0,
      headDist: 2.0,
      groundDist: 2.0,
      obstacle: false,
      aiText: 'System initializing...',
      stickAngleCorrect: true,
      gsmConnected: true,
      nrfFallbackActive: false,
      systemStatus: SystemState.online,
    );
    _timer = Timer.periodic(const Duration(milliseconds: 800), _tick);

    _initLocationStream();
    _initBluetooth();
  }

  Future<void> _initLocationStream() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) return;

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );
      if (!mounted) return;
      setState(() {
        _lastPhonePosition = pos;
        _data = _data.copyWith(lat: pos.latitude, lon: pos.longitude);
      });
    } catch (e) {
      debugPrint('Error getting initial location: $e');
    }

    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 2,
      ),
    ).listen((pos) {
      if (!mounted) return;
      setState(() {
        _lastPhonePosition = pos;
        _data = _data.copyWith(lat: pos.latitude, lon: pos.longitude);
      });
    });
  }

  Future<void> _initBluetooth() async {
    await Permission.bluetoothConnect.request();
    await Permission.bluetoothScan.request();
    await Permission.location.request();

    try {
      BluetoothDevice? stickDevice;
      List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();

      for (var d in devices) {
        // Ensure this matches your ESP32 Bluetooth Name
        if (d.name == "VisionStick_BT" || d.name == "ESP32_BlindStick") {
          stickDevice = d;
          break;
        }
      }

      if (stickDevice != null) {
        setState(() => _btStatus = "Connecting...");
        BluetoothConnection.toAddress(stickDevice.address).then((connection) {
          debugPrint('Connected to the device');
          _connection = connection;
          setState(() => _btStatus = "Connected");

          connection.input!.listen(_onDataReceived).onDone(() {
            setState(() => _btStatus = "Disconnected");
          });
        }).catchError((error) {
          setState(() => _btStatus = "Connection Error");
        });
      } else {
        setState(() => _btStatus = "Stick not paired!");
      }
    } catch (e) {
      debugPrint("Bluetooth Error: $e");
    }
  }

  // Improved Data Receiver with Buffering
  void _onDataReceived(Uint8List data) {
    String chunk = String.fromCharCodes(data);
    _btBuffer += chunk;

    // Process complete messages (delimited by newline)
    while (_btBuffer.contains('\n')) {
      int index = _btBuffer.indexOf('\n');
      String msg = _btBuffer.substring(0, index).trim();
      _btBuffer = _btBuffer.substring(index + 1);

      if (msg.startsWith("TLM")) {
        _parseTelemetry(msg);
      }
    }
  }

  void _parseTelemetry(String msg) {
    // Protocol: TLM,Lat,Lon,HeadDist,GroundZones,StickAngleOk
    // Example: TLM,28.4,77.8,1200,5,1
    List<String> parts = msg.split(',');
    if (parts.length >= 6) {
      try {
        // Hardware GPS values (if valid)
        double hwLat = double.tryParse(parts[1]) ?? 0.0;
        double hwLon = double.tryParse(parts[2]) ?? 0.0;
        
        // Use Phone GPS if Hardware GPS is 0.0 (Fallback logic)
        double finalLat = (hwLat != 0.0) ? hwLat : (_lastPhonePosition?.latitude ?? _data.lat);
        double finalLon = (hwLon != 0.0) ? hwLon : (_lastPhonePosition?.longitude ?? _data.lon);

        double head = double.parse(parts[3]) / 1000.0; // mm to meters
        int zones = int.parse(parts[4]);
        bool angleOk = parts[5] == "1";

        bool obstacle = head < 1.0 || zones > 0; // Trigger if anything detected

        if (mounted) {
          setState(() {
            _data = _data.copyWith(
              lat: finalLat,
              lon: finalLon,
              headDist: head,
              groundDist: zones > 0 ? 0.5 : 2.0, // Simplified ground logic
              obstacle: obstacle,
              stickAngleCorrect: angleOk,
            );
          });

          // Trigger AI if obstacle is very close and we aren't already busy
          if (obstacle && head < 0.8 && !_aiBusy) {
            _runObjectDetection(head);
          }
        }
      } catch (e) {
        debugPrint("Parse Error: $e");
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tts.stop();
    _connection?.dispose();
    _posSub?.cancel();
    super.dispose();
  }

  void _tick(Timer t) {
    // Shutdown logic
    if (_data.systemStatus != SystemState.online) {
      if (_data.systemStatus == SystemState.preparingToSleep && !_shutdownCountdownActive) {
        Future.delayed(const Duration(seconds: 25), () {
          if (mounted) {
            setState(() {
              _data = _data.copyWith(systemStatus: SystemState.shutDown);
              _alerts.insert(0, 'System Shut Down • ${TimeOfDay.now().format(context)}');
            });
          }
        });
        _shutdownCountdownActive = true;
      }
      return;
    }
  }

  Future<void> _speak() async {
    if (_audioBusy) return;
    setState(() => _audioBusy = true);
    try {
      await _tts.setLanguage('en-US');
      await _tts.speak(_data.aiText);
    } finally {
      setState(() => _audioBusy = false);
    }
  }

  Future<Uint8List?> _captureImageFromEsp() async {
    try {
      final uri = Uri.parse(_espCaptureUrl);
      debugPrint('Fetching image from $uri...');
      final response = await http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        return response.bodyBytes;
      } else {
        debugPrint('ESP Capture Failed: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('ESP Capture Error: $e');
      return null;
    }
  }

  Future<void> _runObjectDetection(double frontDistance) async {
    if (_aiBusy) return;
    setState(() {
      _aiBusy = true;
      _data = _data.copyWith(aiText: 'Scanning scene...');
    });

    // 1. Capture Image
    final Uint8List? imageBytes = await _captureImageFromEsp();

    if (imageBytes == null || imageBytes.isEmpty) {
      setState(() {
        _aiBusy = false;
        _data = _data.copyWith(aiText: 'Vision sensor error.');
      });
      return;
    }

    String description = '';
    
    // 2. Gemini Analysis
    try {
      final content = [
        Content.multi([
          TextPart('You are a guide for a blind person. Briefly describe the obstacle directly in front of me in one short sentence. Warning first.'),
          DataPart('image/jpeg', imageBytes),
        ])
      ];

      final response = await _geminiModel.generateContent(content);

      if (response.text != null) {
        description = response.text!.replaceAll('*', '').trim();
      } else {
        description = 'Obstacle detected.';
      }
    } catch (e) {
      debugPrint('Gemini AI Failed: $e');
      description = 'Connection error. Be careful.';
    }

    // 3. Update UI & Speak
    if (mounted) {
      setState(() {
        _aiBusy = false;
        _data = _data.copyWith(aiText: description);
        _alerts.insert(0, 'AI: $description • ${TimeOfDay.now().format(context)}');
        if (_alerts.length > 5) _alerts.removeLast();
      });
      await _speak();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 900;
    final isOffline = _data.systemStatus == SystemState.shutDown;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF020617), // Very dark slate
              Color(0xFF1E1B4B), // Dark indigo
              Color(0xFF312E81), // Indigo
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _buildTopBar(),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        _LiveFeedCard(
                          obstacle: _data.obstacle,
                          headDist: _data.headDist,
                          groundDist: _data.groundDist,
                          espCamUrl: _espStreamUrl,
                        ),
                        const SizedBox(height: 14),
                        _AudioFeedbackCard(
                          onReplay: _speak,
                          busy: _audioBusy,
                        ),
                        const SizedBox(height: 14),
                        _LocationCard(
                          lat: isOffline ? 0.0 : _data.lat,
                          lon: isOffline ? 0.0 : _data.lon,
                          onOpenInMaps: _openInGoogleMaps,
                        ),
                        const SizedBox(height: 14),
                        _AiAnalysisCard(text: _data.aiText),
                        const SizedBox(height: 14),
                        _AlertsCard(alerts: _alerts),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    String statusText;
    Color statusColor;
    Color statusIconColor;
    IconData statusIcon;

    switch (_data.systemStatus) {
      case SystemState.online:
        statusText = 'SYSTEM ONLINE';
        statusColor = const Color(0xFF10B981);
        statusIconColor = const Color(0xFF34D399);
        statusIcon = Icons.wifi;
        break;
      case SystemState.preparingToSleep:
        statusText = 'ENTERING SLEEP MODE';
        statusColor = const Color(0xFFFACC15);
        statusIconColor = const Color(0xFFFDE047);
        statusIcon = Icons.hourglass_top;
        break;
      case SystemState.shutDown:
        statusText = 'OFFLINE';
        statusColor = const Color(0xFFEF4444);
        statusIconColor = const Color(0xFFF87171);
        statusIcon = Icons.power_off;
        break;
    }

    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
                colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)]),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF6366F1).withOpacity(0.4),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(Icons.remove_red_eye_rounded,
              size: 22, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'VISION ASSIST',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.0,
                color: Colors.white,
              ),
            ),
            Text(
              _btStatus,
              style: TextStyle(
                fontSize: 10,
                color: _btStatus == "Connected" ? Colors.greenAccent : Colors.white54,
              ),
            ),
          ],
        ),
        const Spacer(),
        if (!_data.stickAngleCorrect &&
            _data.systemStatus == SystemState.online)
          const _ImuStatusPill(),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: statusColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: statusColor.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              Icon(statusIcon, size: 14, color: statusIconColor),
              const SizedBox(width: 8),
              Text(
                statusText,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ... Keep your existing helper widgets (_ImuStatusPill, _CardShell, _LiveFeedCard, etc.) exactly as they were ...
// To save space, I have not pasted the UI widgets below this line as they remain unchanged.
// Just ensure you keep the classes: _ImuStatusPill, _CardShell, _LiveFeedCard, _AudioFeedbackCard, _LocationCard, _AiAnalysisCard, _AlertsCard