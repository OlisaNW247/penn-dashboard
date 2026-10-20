import Testing

/// One serialized parent for every suite that drives the announcement and Ed
/// extraction loops (`syncAnnouncements`, `syncEdAnnouncementTasks`) through
/// the shared defaults domain.
///
/// All three write the same process-wide keys (`processedAnnouncementIDsV1`,
/// `edTaskRetryAfterV1`, `announcementExtractionVersionV1`, the retry counters
/// and the back-off), each backing them up and restoring them. A `.serialized`
/// trait on a suite only orders that suite's own tests, so two of these suites
/// could still run at once and see each other's writes (the shared-defaults
/// trap in CLAUDE.md). Nesting them under one `.serialized` parent makes
/// swift-testing run all of their tests one after another, and keeps each
/// suite's own name.
///
/// A new suite that writes those keys belongs here too:
/// `extension AnnouncementExtractionSuites { @Suite struct … }`.
@Suite("Announcement extraction suites", .serialized)
enum AnnouncementExtractionSuites {}
