package com.smartheritage.personalization.client;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.smartheritage.common.web.ApiException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

import java.util.List;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.*;

class ArtifactClientFallbackTest {
    private StringRedisTemplate redis;
    private ValueOperations<String, String> values;
    private MockRestServiceServer server;
    private ArtifactClient client;
    private final ObjectMapper mapper = new ObjectMapper();

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        redis = mock(StringRedisTemplate.class);
        values = mock(ValueOperations.class);
        when(redis.opsForValue()).thenReturn(values);
        RestClient.Builder builder = RestClient.builder().baseUrl("http://content.test");
        server = MockRestServiceServer.bindTo(builder).build();
        client = new ArtifactClient(builder.build(), redis, mapper);
    }

    @Test
    void redisFailureFallsBackToContentIncludingActiveValidation() {
        when(redis.opsForValue()).thenThrow(new RedisConnectionFailureException("offline"));
        server.expect(requestTo("http://content.test/api/artifacts/1"))
                .andRespond(withSuccess("""
                        {"data":{"id":1,"name":"Artifact","status":"ACTIVE","siteId":2}}
                        """, MediaType.APPLICATION_JSON));
        assertEquals("Artifact", client.requireActive(1L).name());
        server.verify();
    }

    @Test
    void warmCacheWorksWithoutContactingContent() throws Exception {
        var snapshot = new ArtifactClient.ArtifactSnapshot(1L, 2L, "Site", "Cached", null, "ACTIVE");
        when(values.get("artifact:summary:1")).thenReturn(mapper.writeValueAsString(snapshot));
        assertEquals("Cached", client.getMany(List.of(1L)).get(1L).name());
        server.verify();
    }

    @Test
    void coldCacheAndContentDownDegradesMetadataAndDoesNotRepeatFailedRequest() throws Exception {
        var cached = new ArtifactClient.ArtifactSnapshot(3L, 2L, "Site", "Cached", null, "ACTIVE");
        when(values.get("artifact:summary:3")).thenReturn(mapper.writeValueAsString(cached));
        server.expect(requestTo("http://content.test/api/artifacts/1")).andRespond(withStatus(HttpStatus.SERVICE_UNAVAILABLE));
        var result = client.getMany(List.of(1L, 2L, 3L, 1L));
        assertEquals(List.of(3L), List.copyOf(result.keySet()));
        assertEquals("Cached", result.get(3L).name());
        server.verify();
    }

    @Test
    void degradedReadsNeverAllowAnUnverifiedWrite() {
        server.expect(requestTo("http://content.test/api/artifacts/1")).andRespond(withStatus(HttpStatus.SERVICE_UNAVAILABLE));
        var error = assertThrows(ApiException.class, () -> client.requireActive(1L));
        assertEquals(HttpStatus.SERVICE_UNAVAILABLE, error.getStatus());
        server.verify();
    }

    @Test
    void deletedArtifactDoesNotHideOtherMetadata() {
        server.expect(requestTo("http://content.test/api/artifacts/1")).andRespond(withStatus(HttpStatus.NOT_FOUND));
        server.expect(requestTo("http://content.test/api/artifacts/2"))
                .andRespond(withSuccess("{\"data\":{\"id\":2,\"status\":\"ACTIVE\"}}", MediaType.APPLICATION_JSON));
        assertEquals(List.of(2L), List.copyOf(client.getMany(List.of(1L, 2L)).keySet()));
        server.verify();
    }
}
