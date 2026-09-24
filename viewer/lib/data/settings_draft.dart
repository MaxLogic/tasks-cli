/// Viewer preferences as edited in Settings.
///
/// Persistence, corruption handling and atomic replacement land with the data
/// client slice; this type is the shared value object either way.
library;

import '../controllers/announcement_controller.dart';
import 'models.dart';

/// Theme choice for the window.
enum ViewerThemeMode {
  system,
  light,
  dark,
  highContrastLight,
  highContrastDark,
}

/// Text-size choices offered by Settings (design.md section 3).
const List<int> viewerTextScalePercentChoices = <int>[100, 125, 150, 175, 200];

/// One settings document.
class ViewerSettingsDraft {
  const ViewerSettingsDraft({
    this.cliPath,
    this.dataRoot,
    this.themeMode = ViewerThemeMode.system,
    this.textScalePercent = 100,
    this.projectsPanePercent = 22,
    this.tasksPanePercent = 33,
    this.detailsPanePercent = 45,
    this.startWithWindows = true,
    this.announcementMode = AnnouncementMode.bella,
    this.bellaVolumePercent = 70,
    this.projectState = ProjectStateFilter.hasOpen,
    this.projectSort = ProjectSort.lastWrite,
    this.projectDirection = SortDirection.descending,
  });

  /// Absolute path of the tasks executable, or null when unresolved.
  final String? cliPath;

  /// Absolute task store root, or null until one is chosen.
  final String? dataRoot;

  final ViewerThemeMode themeMode;
  final int textScalePercent;
  final int projectsPanePercent;
  final int tasksPanePercent;
  final int detailsPanePercent;

  /// Desired Windows-startup state; registration success is tracked apart.
  final bool startWithWindows;

  final AnnouncementMode announcementMode;
  final int bellaVolumePercent;
  final ProjectStateFilter projectState;
  final ProjectSort projectSort;
  final SortDirection projectDirection;

  ViewerSettingsDraft copyWith({
    String? cliPath,
    bool clearCliPath = false,
    String? dataRoot,
    bool clearDataRoot = false,
    ViewerThemeMode? themeMode,
    int? textScalePercent,
    int? projectsPanePercent,
    int? tasksPanePercent,
    int? detailsPanePercent,
    bool? startWithWindows,
    AnnouncementMode? announcementMode,
    int? bellaVolumePercent,
    ProjectStateFilter? projectState,
    ProjectSort? projectSort,
    SortDirection? projectDirection,
  }) {
    return ViewerSettingsDraft(
      cliPath: clearCliPath ? null : (cliPath ?? this.cliPath),
      dataRoot: clearDataRoot ? null : (dataRoot ?? this.dataRoot),
      themeMode: themeMode ?? this.themeMode,
      textScalePercent: textScalePercent ?? this.textScalePercent,
      projectsPanePercent: projectsPanePercent ?? this.projectsPanePercent,
      tasksPanePercent: tasksPanePercent ?? this.tasksPanePercent,
      detailsPanePercent: detailsPanePercent ?? this.detailsPanePercent,
      startWithWindows: startWithWindows ?? this.startWithWindows,
      announcementMode: announcementMode ?? this.announcementMode,
      bellaVolumePercent: bellaVolumePercent ?? this.bellaVolumePercent,
      projectState: projectState ?? this.projectState,
      projectSort: projectSort ?? this.projectSort,
      projectDirection: projectDirection ?? this.projectDirection,
    );
  }

  /// Convenience accessors used by the shell and tests.
  AnnouncementMode get effectiveAnnouncementMode => announcementMode;

  double get bellaVolume => (bellaVolumePercent.clamp(0, 100)) / 100;
}
