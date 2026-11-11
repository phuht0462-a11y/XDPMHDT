package com.smartheritage.personalization.event;

import java.util.List;

/** ArtifactUpdated data sent by content-service after artifact/media changes. */
public record ArtifactUpdatedData(Long artifactId, Long siteId, List<String> changedFields,
                                  String updatedAt) {
}
