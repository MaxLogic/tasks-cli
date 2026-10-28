import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Flutter's Windows embedder does not expose the client-area animation flag.
/// API failure retains the platform default; Off in Settings still wins.
bool readWindowsAnimationsEnabled() {
  if (!Platform.isWindows) return true;
  final value = calloc<Int32>();
  try {
    final result = SystemParametersInfo(
      SPI_GETCLIENTAREAANIMATION,
      0,
      value,
      const SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
    );
    return !result.value || value.value != 0;
  } finally {
    calloc.free(value);
  }
}
