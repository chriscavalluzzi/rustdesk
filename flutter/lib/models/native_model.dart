import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info/device_info.dart';
import 'package:external_path/external_path.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../common.dart';
import '../generated_bridge.dart';

class RgbaFrame extends Struct {
  @Uint32()
  external int len;
  external Pointer<Uint8> data;
}

typedef F2 = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef F3 = void Function(Pointer<Utf8>, Pointer<Utf8>);

/// FFI wrapper around the native Rust core.
/// Hides the platform differences.
class PlatformFFI {
  static Pointer<RgbaFrame>? _lastRgbaFrame;
  static String _dir = '';
  static String _homeDir = '';
  static F2? _getByName;
  static F3? _setByName;
  static void Function(Map<String, dynamic>)? _eventCallback;
  static void Function(Uint8List)? _rgbaCallback;

  static Future<String> getVersion() async {
    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  /// Send **get** command to the Rust core based on [name] and [arg].
  /// Return the result as a string.
  static String getByName(String name, [String arg = '']) {
    if (_getByName == null) return '';
    var a = name.toNativeUtf8();
    var b = arg.toNativeUtf8();
    var p = _getByName!(a, b);
    assert(p != nullptr);
    var res = p.toDartString();
    calloc.free(p);
    calloc.free(a);
    calloc.free(b);
    return res;
  }

  /// Send **set** command to the Rust core based on [name] and [value].
  static void setByName(String name, [String value = '']) {
    if (_setByName == null) return;
    var a = name.toNativeUtf8();
    var b = value.toNativeUtf8();
    _setByName!(a, b);
    calloc.free(a);
    calloc.free(b);
  }

  /// Init the FFI class, loads the native Rust core library.
  static Future<Null> init() async {
    isIOS = Platform.isIOS;
    isAndroid = Platform.isAndroid;
    isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    // if (isDesktop) {
    //   // TODO
    //   return;
    // }
    final dylib = Platform.isAndroid
        ? DynamicLibrary.open('librustdesk.so')
        : Platform.isLinux
            ? DynamicLibrary.open("/usr/lib/rustdesk/librustdesk.so")
            : Platform.isWindows
                ? DynamicLibrary.open("librustdesk.dll")
                : Platform.isMacOS
                    ? DynamicLibrary.open("librustdesk.dylib")
                    : DynamicLibrary.process();
    print('initializing FFI');
    try {
      _getByName = dylib.lookupFunction<F2, F2>('get_by_name');
      _setByName =
          dylib.lookupFunction<Void Function(Pointer<Utf8>, Pointer<Utf8>), F3>(
              'set_by_name');
      _dir = (await getApplicationDocumentsDirectory()).path;
      _startListenEvent(RustdeskImpl(dylib));
      try {
        _homeDir = (await ExternalPath.getExternalStorageDirectories())[0];
      } catch (e) {
        print(e);
      }
      String id = 'NA';
      String name = 'Flutter';
      DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        name = '${androidInfo.brand}-${androidInfo.model}';
        id = androidInfo.id.hashCode.toString();
        androidVersion = androidInfo.version.sdkInt;
      } else {
        IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
        name = iosInfo.utsname.machine;
        id = iosInfo.identifierForVendor.hashCode.toString();
      }
      print("info1-id:$id,info2-name:$name,dir:$_dir,homeDir:$_homeDir");
      setByName('info1', id);
      setByName('info2', name);
      setByName('home_dir', _homeDir);
      setByName('init', _dir);
    } catch (e) {
      print(e);
    }
    version = await getVersion();
  }

  /// Start listening to the Rust core's events and frames.
  static void _startListenEvent(RustdeskImpl rustdeskImpl) {
    () async {
      await for (final message in rustdeskImpl.startEventStream()) {
        if (_eventCallback != null) {
          try {
            Map<String, dynamic> event = json.decode(message);
            _eventCallback!(event);
          } catch (e) {
            print('json.decode fail(): $e');
          }
        }
      }
    }();
    () async {
      await for (final rgba in rustdeskImpl.startRgbaStream()) {
        if (_rgbaCallback != null) {
          _rgbaCallback!(rgba);
        } else {
          rgba.clear();
        }
      }
    }();
  }

  static void setEventCallback(void Function(Map<String, dynamic>) fun) async {
    _eventCallback = fun;
  }

  static void setRgbaCallback(void Function(Uint8List) fun) async {
    _rgbaCallback = fun;
  }

  static void startDesktopWebListener() {}

  static void stopDesktopWebListener() {}

  static void setMethodCallHandler(FMethod callback) {
    toAndroidChannel.setMethodCallHandler((call) async {
      callback(call.method, call.arguments);
      return null;
    });
  }

  static invokeMethod(String method, [dynamic arguments]) async {
    if (!isAndroid) return Future<bool>(() => false);
    return await toAndroidChannel.invokeMethod(method, arguments);
  }
}

final localeName = Platform.localeName;
final toAndroidChannel = MethodChannel("mChannel");
