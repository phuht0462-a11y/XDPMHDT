package com.smartheritage.personalization.event;

import com.smartheritage.common.events.EventEnvelope;
import com.smartheritage.personalization.config.ArtifactUpdatedQueueConfig;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.UUID;

/** Invalidates summary cache used by ArtifactClient upon artifact.updated. */
@Component
public class ArtifactUpdatedListener {
    private static final Logger log = LoggerFactory.getLogger(ArtifactUpdatedListener.class);
    private static final String PROCESSED_PREFIX = "personalization:processed:artifact.updated:";
    private static final Duration PROCESSED_TTL = Duration.ofDays(7);
    private final StringRedisTemplate redis;

    public ArtifactUpdatedListener(StringRedisTemplate redis) {
        this.redis = redis;
    }

    @RabbitListener(queues = ArtifactUpdatedQueueConfig.QUEUE)
    public void onArtifactUpdated(EventEnvelope<ArtifactUpdatedData> event) {
        if (event == null || !"ArtifactUpdated".equals(event.type())
                || event.data() == null || event.data().artifactId() == null
                || event.data().artifactId() <= 0) {
            throw new IllegalArgumentException("Sự kiện ArtifactUpdated không hợp lệ");
        }
        UUID eventId = event.eventId();
        String processedKey = eventId == null ? null : PROCESSED_PREFIX + eventId;
        if (processedKey != null && Boolean.TRUE.equals(redis.hasKey(processedKey))) {
            log.debug("Bỏ qua ArtifactUpdated trùng eventId={}", eventId);
            return;
        }
        String key = "artifact:summary:" + event.data().artifactId();
        Boolean removed = redis.delete(key);
        if (processedKey != null) {
            redis.opsForValue().set(processedKey, "1", PROCESSED_TTL);
        }
        log.info("ArtifactUpdated eventId={} artifactId={} cacheKey={} deleted={}",
                eventId, event.data().artifactId(), key, removed);
    }
}
