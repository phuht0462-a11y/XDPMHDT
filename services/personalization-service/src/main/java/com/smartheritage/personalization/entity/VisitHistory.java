package com.smartheritage.personalization.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Index;
import jakarta.persistence.PrePersist;
import jakarta.persistence.Table;
import jakarta.persistence.UniqueConstraint;
import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.LocalDateTime;

@Entity
@Table(name = "visits", indexes = @Index(name = "idx_visits_user_detected", columnList = "user_id, detected_at"), uniqueConstraints = @UniqueConstraint(
        name = "uq_visits_user_event", columnNames = {"user_id", "client_event_id"}))
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class VisitHistory {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "user_id", nullable = false)
    private Long userId;

    @Column(name = "artifact_id", nullable = false)
    private Long artifactId;

    @Column(name = "detected_at", nullable = false)
    private LocalDateTime detectedAt;

    @Column(name = "duration_seconds")
    private Integer durationSeconds;

    @Column(name = "client_event_id", length = 36)
    private String clientEventId;

    @Column(name = "source", nullable = false, length = 20)
    @Builder.Default
    private String source = "MANUAL";

    @PrePersist
    void beforeInsert() {
        if (detectedAt == null) detectedAt = LocalDateTime.now();
        if (source == null || source.isBlank()) source = "MANUAL";
    }
}
