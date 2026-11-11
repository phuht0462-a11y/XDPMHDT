package com.smartheritage.personalization.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.smartheritage.common.web.ApiException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.http.HttpStatus;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import java.time.Duration;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Gọi content-service/Backend cũ; personalization_db không join chéo database. */
@Component
public class ArtifactClient {
    private static final Logger log = LoggerFactory.getLogger(ArtifactClient.class);
    private static final String UNAVAILABLE = "Không kết nối được dịch vụ hiện vật (content-service), vui lòng thử lại sau!";

    private static final String SUMMARY_PREFIX = "artifact:summary:";
    private static final Duration CACHE_TTL = Duration.ofMinutes(10);
    private final RestClient restClient;
    private final StringRedisTemplate redis;
    private final ObjectMapper objectMapper;

    public ArtifactClient(@Qualifier("contentRestClient") RestClient restClient,
                          StringRedisTemplate redis, ObjectMapper objectMapper) {
        this.restClient = restClient;
        this.redis = redis;
        this.objectMapper = objectMapper;
    }

    public ArtifactSnapshot requireActive(Long artifactId) {
        ArtifactSnapshot artifact = get(artifactId);
        if (!"ACTIVE".equalsIgnoreCase(artifact.status())) {
            throw new ApiException(HttpStatus.CONFLICT, "Hiện vật hiện không khả dụng.");
        }
        return artifact;
    }

    public ArtifactSnapshot get(Long artifactId) {
        ArtifactSnapshot cached = readCache(artifactId);
        if (cached != null) return cached;
        try {
            JsonNode body = restClient.get()
                    .uri("/api/artifacts/{id}", artifactId)
                    .retrieve()
                    .body(JsonNode.class);
            JsonNode data = body == null ? null : body.get("data");
            if (data == null || !data.isObject()) {
                throw ApiException.serviceUnavailable(UNAVAILABLE);
            }
            ArtifactSnapshot fresh = snapshot(data);
            writeCache(artifactId, fresh);
            return fresh;
        } catch (HttpClientErrorException.NotFound ex) {
            throw ApiException.notFound("Không tìm thấy hiện vật với ID: " + artifactId);
        } catch (ApiException ex) {
            throw ex;
        } catch (RestClientException ex) {
            log.warn("Gọi content-service lỗi cho hiện vật {}: {}", artifactId, ex.getMessage());
            throw ApiException.serviceUnavailable(UNAVAILABLE);
        }
    }

    /** Giữ thứ tự id và bỏ qua hiện vật đã bị xóa; lỗi kết nối vẫn trả 503 để app dùng cache offline. */
    public Map<Long, ArtifactSnapshot> getMany(Collection<Long> artifactIds) {
        Set<Long> unique = new LinkedHashSet<>(artifactIds);
        Map<Long, ArtifactSnapshot> result = new LinkedHashMap<>();
        for (Long id : unique) {
            if (id == null) continue;
            try {
                result.put(id, get(id));
            } catch (ApiException ex) {
                if (ex.getStatus() != HttpStatus.NOT_FOUND) throw ex;
            }
        }
        return result;
    }

    public List<ArtifactSnapshot> listBySite(Long siteId) {
        try {
            JsonNode body = restClient.get()
                    .uri(uriBuilder -> uriBuilder.path("/api/artifacts").queryParam("siteId", siteId).build())
                    .retrieve()
                    .body(JsonNode.class);
            JsonNode data = body == null ? null : body.get("data");
            if (data == null || !data.isArray()) {
                throw ApiException.serviceUnavailable(UNAVAILABLE);
            }
            return java.util.stream.StreamSupport.stream(data.spliterator(), false)
                    .filter(JsonNode::isObject)
                    .map(this::snapshot)
                    .toList();
        } catch (ApiException ex) {
            throw ex;
        } catch (RestClientException ex) {
            log.warn("Gọi content-service lỗi khi lọc site {}: {}", siteId, ex.getMessage());
            throw ApiException.serviceUnavailable(UNAVAILABLE);
        }
    }

    private ArtifactSnapshot snapshot(JsonNode node) {
        Long id = longValue(node, "id");
        Long siteId = longValue(node, "siteId");
        if (siteId == null) siteId = longValue(node, "locationId");
        return new ArtifactSnapshot(
                id,
                siteId,
                text(node, "locationName"),
                text(node, "name"),
                text(node, "thumbnailUrl"),
                text(node, "status"));
    }

    private static Long longValue(JsonNode node, String field) {
        JsonNode value = node.get(field);
        return value == null || value.isNull() || !value.canConvertToLong() ? null : value.longValue();
    }

    private static String text(JsonNode node, String field) {
        JsonNode value = node.get(field);
        return value == null || value.isNull() ? null : value.asText();
    }

    private ArtifactSnapshot readCache(Long artifactId) {
        try {
            String json = redis.opsForValue().get(SUMMARY_PREFIX + artifactId);
            return json == null ? null : objectMapper.readValue(json, ArtifactSnapshot.class);
        } catch (Exception ex) {
            log.warn("Không đọc được Redis cache hiện vật {}: {}", artifactId, ex.getMessage());
            return null; // Redis down or corrupt cache: fall back to content-service.
        }
    }

    private void writeCache(Long artifactId, ArtifactSnapshot snapshot) {
        try {
            redis.opsForValue().set(SUMMARY_PREFIX + artifactId,
                    objectMapper.writeValueAsString(snapshot), CACHE_TTL);
        } catch (Exception ex) {
            log.warn("Không lưu được Redis cache hiện vật {}: {}", artifactId, ex.getMessage());
        }
    }

    public record ArtifactSnapshot(Long id, Long siteId, String siteName,
                                   String name, String thumbnailUrl, String status) {
    }
}
