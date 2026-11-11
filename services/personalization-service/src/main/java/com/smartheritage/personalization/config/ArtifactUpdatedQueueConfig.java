package com.smartheritage.personalization.config;

import com.smartheritage.common.events.Events;
import org.springframework.amqp.core.Binding;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.Declarables;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.QueueBuilder;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** Own queue, three-attempt listener retry, then durable dead-letter queue. */
@Configuration
public class ArtifactUpdatedQueueConfig {
    public static final String QUEUE = "personalization.artifact-updated";
    public static final String DLQ = "personalization.artifact-updated.dlq";

    @Bean
    public Declarables personalizationArtifactUpdatedBindings() {
        Queue deadLetter = QueueBuilder.durable(DLQ).build();
        Queue queue = QueueBuilder.durable(QUEUE)
                .deadLetterExchange("")
                .deadLetterRoutingKey(DLQ)
                .build();
        Binding binding = BindingBuilder.bind(queue)
                .to(new TopicExchange(Events.EXCHANGE, true, false))
                .with("artifact.updated");
        return new Declarables(queue, deadLetter, binding);
    }
}
