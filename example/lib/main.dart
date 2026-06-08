import 'package:flutter/material.dart';
import 'package:ota_new_protocol/features/scanningAndConnection/presentation/controller/scanning_connection_controller.dart';
import 'package:ota_new_protocol/routing/routes.dart';
import 'package:ota_new_protocol/utils/colors.dart';

import 'app/app.dart';
import 'app/di.dart';
import 'common/custom_button/feedback_enabled_button.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'core/permissions/bluetooth_adapter.dart';
import 'core/permissions/check_status.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await di();
  await PermissionEnable().check();

  // Request Bluetooth and location permissions
  Map<ph.Permission, ph.PermissionStatus> statuses = await [
    ph.Permission.bluetooth,
    ph.Permission.location,
    ph.Permission.storage, // Add storage permission here
  ].request();
  print("statuses: $statuses");

  BluetoothAdapter.initBleStateStream();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: OTANewApp(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  HomePageController homePageController = Get.find();

  @override
  void initState() {
    super.initState();
    // Attempt to auto-connect to the previously connected device on launch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attemptAutoConnect();
    });
  }

  Future<void> _attemptAutoConnect() async {
    await homePageController.loadLastDevice();
    if (!homePageController.hasLastDevice) return;

    final connected = await homePageController.autoConnectToLastDevice();
    if (!mounted) return;
    if (connected) {
      homePageController.connectedDevice.value = [
        homePageController.gBleDevice!,
      ];
      Get.toNamed(AppRoutes.newOtaUpdate);
    }
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: FeedbackEnabledButton(
                scaleFactor: 1.0,
                translationFactorX: 0.0,
                childWidget: Container(
                  //height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.rectangle,
                    border: Border.all(
                      color: Colors.transparent,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(10.0),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        secondaryColor,
                        secondaryColor,
                      ],
                    ),
                  ),
                  //margin: const EdgeInsets.only(top: 10.0),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          "Start Scanning",
                          style: TextStyle(
                              color: Color(0xFFFFFFFF),
                              fontFamily: 'Inter',
                              fontSize: 16,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ),
                onTap: () async {
                  if (await PermissionEnable().check() == true) {
                    print("in start scaning");
                    homePageController.scannedDevicesList.clear();
                    print("Going to scaaning view page");
                    Get.toNamed(AppRoutes.scanning);
                    await homePageController.scanningMethod();
                  } else {
                    print("permission denied");
                  }
                },
              ),

              /*GestureDetector(
                        onTap: (){
                          print("Tapped");
                          Get.offNamed(AppRoutes.addNewLeoDevice);
                        },
                        child:
                      )*/
            ),
            Obx(() {
              if (!homePageController.hasLastDevice) {
                return const SizedBox.shrink();
              }
              final bool busy = homePageController.isAutoConnecting.value;
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          final connected = await homePageController
                              .autoConnectToLastDevice();
                          if (!mounted) return;
                          if (connected) {
                            Get.toNamed(AppRoutes.newOtaUpdate);
                          }
                        },
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.history),
                  label: Text(
                    busy
                        ? "Connecting to ${homePageController.lastDeviceName.value}..."
                        : "Reconnect to ${homePageController.lastDeviceName.value}",
                  ),
                ),
              );
            }),
          ],
        ),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
