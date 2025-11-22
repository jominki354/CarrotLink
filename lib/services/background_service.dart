import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'carrot_link_service', // id
    'CarrotLink Service', // title
    description: 'CarrotLink Background Service', // description
    importance: Importance.high, // high importance to ensure visibility
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('launcher_icon'),
      iOS: DarwinInitializationSettings(),
    ),
  );

  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      // this will be executed when app is in foreground or background in separated isolate
      onStart: onStart,

      // auto start service
      autoStart: false,
      isForegroundMode: true,

      notificationChannelId: 'carrot_link_service',
      initialNotificationTitle: 'CarrotLink 서비스 실행 중',
      initialNotificationContent: '백업 및 모니터링이 활성화되었습니다.',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  // Only available for flutter 3.0.0 and later
  DartPluginRegistrant.ensureInitialized();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Create the channel in the background isolate as well
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'carrot_link_service', // id
    'CarrotLink Service', // title
    description: 'CarrotLink Background Service', // description
    importance: Importance.high, // high importance to ensure visibility
  );

  await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('launcher_icon'),
      iOS: DarwinInitializationSettings(),
    ),
  );

  // Force show notification immediately to ensure service is visible
  await flutterLocalNotificationsPlugin.show(
    888,
    'CarrotLink 서비스 실행 중',
    '백업 및 모니터링이 활성화되었습니다.',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'carrot_link_service',
        'CarrotLink Service',
        icon: 'launcher_icon',
        ongoing: true,
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );

  service.on('updateNotification').listen((event) {
    if (event != null) {
      final String content = event['content'] as String? ?? '';
      if (content.isNotEmpty) {
        flutterLocalNotificationsPlugin.show(
          888,
          'CarrotLink 서비스 실행 중',
          content,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'carrot_link_service',
              'CarrotLink Service',
              icon: 'launcher_icon',
              ongoing: true,
            ),
          ),
        );
      }
    }
  });

  // Keep the service alive with a timer
  Timer.periodic(const Duration(minutes: 1), (timer) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        // Optional: Update notification to show it's alive
        // flutterLocalNotificationsPlugin.show(...)
      }
    }
  });
  
  service.on('stopService').listen((event) {
    service.stopSelf();
  });
}
