package com.smartheritage.personalization.event;

import com.smartheritage.common.events.EventPublisher;
import com.smartheritage.common.events.Events;
import com.smartheritage.personalization.entity.VisitHistory;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.stereotype.Component;

/** One event per new visit, only after successful database commit. */
@Component
public class VisitEventPublisher {
    public static final String TYPE = "VisitRecorded";
    public static final String ROUTING_KEY = "visit.recorded";
    private final EventPublisher publisher;

    public VisitEventPublisher(EventPublisher publisher, MeterRegistry meterRegistry) {
        this.publisher = publisher;
        for (String result : new String[]{Events.RESULT_SUCCESS, Events.RESULT_FAILED}) {
            meterRegistry.counter(Events.METRIC_PUBLISHED, "type", TYPE, "result", result);
        }
    }

    public void publishRecorded(VisitHistory visit, Long siteId) {
        VisitEventData data = new VisitEventData(
                visit.getId(), visit.getUserId(), visit.getArtifactId(), siteId,
                visit.getDetectedAt(), visit.getDurationSeconds(), visit.getSource());
        publisher.publishAfterCommit(ROUTING_KEY, TYPE, data);
    }
}
