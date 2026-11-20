package com.smartheritage.personalization.service;

import com.smartheritage.personalization.client.ArtifactClient;
import com.smartheritage.personalization.entity.Favorite;
import com.smartheritage.personalization.entity.FavoriteId;
import com.smartheritage.personalization.entity.VisitHistory;
import com.smartheritage.personalization.event.VisitEventPublisher;
import com.smartheritage.personalization.repository.FavoriteRepository;
import com.smartheritage.personalization.repository.VisitHistoryRepository;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.PageRequest;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class PersonalDataFallbackTest {
    @Test
    void missingMetadataKeepsFavoriteIdAndSavedTime() {
        var repository = mock(FavoriteRepository.class);
        var artifacts = mock(ArtifactClient.class);
        var pageable = PageRequest.of(0, 20);
        var time = LocalDateTime.of(2026, 11, 19, 9, 30);
        when(repository.findByIdUserIdOrderBySavedAtDesc(6L, pageable)).thenReturn(
                new PageImpl<>(List.of(Favorite.builder().id(new FavoriteId(6L, 1L)).savedAt(time).build())));
        when(artifacts.getMany(List.of(1L))).thenReturn(Map.of());
        var result = new FavoriteService(repository, artifacts).list(6L, pageable);
        assertEquals(1, result.getTotalElements());
        var row = result.getContent().get(0);
        assertEquals(1L, row.artifactId());
        assertEquals("Hiện vật #1", row.artifactName());
        assertEquals(time, row.savedAt());
    }

    @Test
    void missingMetadataKeepsVisitIdentityAndOriginalEventId() {
        var repository = mock(VisitHistoryRepository.class);
        var artifacts = mock(ArtifactClient.class);
        var pageable = PageRequest.of(0, 20);
        var time = LocalDateTime.of(2026, 11, 19, 9, 30);
        var event = "00000000-0000-4000-8000-000000000001";
        when(repository.findByUserIdOrderByDetectedAtDesc(6L, pageable)).thenReturn(
                new PageImpl<>(List.of(VisitHistory.builder().id(10L).userId(6L).artifactId(1L)
                        .detectedAt(time).clientEventId(event).source("BEACON").build())));
        when(artifacts.getMany(List.of(1L))).thenReturn(Map.of());
        var result = new VisitHistoryService(repository, artifacts, mock(VisitEventPublisher.class)).list(6L, pageable);
        assertEquals(1, result.getTotalElements());
        var row = result.getContent().get(0);
        assertEquals(10L, row.id());
        assertEquals(event, row.clientEventId());
        assertEquals(time, row.detectedAt());
        assertEquals("BEACON", row.source());
        assertEquals("Hiện vật #1", row.artifactName());
    }
}
