package com.smartheritage.personalization.event;

import com.smartheritage.common.events.EventEnvelope;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class ArtifactUpdatedListenerTest {
    @SuppressWarnings("unchecked")
    @Test
    void invalidatesSummaryKeyAndIgnoresDuplicateEvent() {
        StringRedisTemplate redis = mock(StringRedisTemplate.class);
        ValueOperations<String, String> values = mock(ValueOperations.class);
        UUID eventId = UUID.randomUUID();
        when(redis.opsForValue()).thenReturn(values);
        when(redis.hasKey("personalization:processed:artifact.updated:" + eventId))
                .thenReturn(false, true);
        ArtifactUpdatedListener listener = new ArtifactUpdatedListener(redis);
        EventEnvelope<ArtifactUpdatedData> event = EventEnvelope.of(eventId, "ArtifactUpdated",
                Instant.now(), new ArtifactUpdatedData(7L, 2L, List.of("name"), "2026-11-11T09:00:00Z"));

        listener.onArtifactUpdated(event);
        listener.onArtifactUpdated(event);

        verify(redis, times(1)).delete("artifact:summary:7");
        verify(values).set(eq("personalization:processed:artifact.updated:" + eventId),
                eq("1"), any(Duration.class));
    }

    @Test
    void cacheFailurePropagatesSoRabbitCanRetryThenDeadLetter() {
        StringRedisTemplate redis = mock(StringRedisTemplate.class);
        when(redis.delete("artifact:summary:7"))
                .thenThrow(new IllegalStateException("Redis unavailable"));
        ArtifactUpdatedListener listener = new ArtifactUpdatedListener(redis);
        EventEnvelope<ArtifactUpdatedData> event = EventEnvelope.of(
                "ArtifactUpdated", new ArtifactUpdatedData(7L, 2L, List.of("name"), null));

        org.junit.jupiter.api.Assertions.assertThrows(IllegalStateException.class,
                () -> listener.onArtifactUpdated(event));
    }
}
