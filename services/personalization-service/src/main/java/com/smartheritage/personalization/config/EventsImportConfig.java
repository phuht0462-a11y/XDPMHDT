package com.smartheritage.personalization.config;

import com.smartheritage.common.events.EventsConfig;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Import;

/** Enable shared RabbitMQ event exchange, JSON converter and publisher. */
@Configuration
@Import(EventsConfig.class)
public class EventsImportConfig {
}
