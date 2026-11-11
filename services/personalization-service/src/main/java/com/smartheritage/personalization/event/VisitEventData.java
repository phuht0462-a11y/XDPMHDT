package com.smartheritage.personalization.event;

import java.time.LocalDateTime;

/** visit.recorded payload consumed by analytics-service. */
public record VisitEventData(Long visitId, Long userId, Long artifactId, Long siteId,
                             LocalDateTime detectedAt, Integer durationSeconds, String source) {
}
