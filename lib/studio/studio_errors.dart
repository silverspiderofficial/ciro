/// Error codes from Studio work, localised by the UI (see S.studioErrorKey).
class StudioException implements Exception {
  const StudioException(this.code, [this.detail = '']);

  /// power_blocked | no_ffmpeg | no_voice | no_model | device_unsupported | low_ram | cancelled |
  /// render_failed | generate_failed | load_failed | busy | no_scenes | missing_image | process_died
  final String code;
  final String detail;

  @override
  String toString() => 'StudioException($code${detail.isEmpty ? '' : ': $detail'})';
}
