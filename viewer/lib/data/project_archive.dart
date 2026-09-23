/// The project archive write surface. Readers that cannot change project
/// metadata leave this capability absent from the workspace.
abstract interface class ProjectArchiveWriter {
  /// Returns the stored archive time, or null when the project is active.
  Future<int?> setProjectArchived(String projectId, {required bool archived});
}
