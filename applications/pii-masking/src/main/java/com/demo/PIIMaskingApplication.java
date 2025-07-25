// applications/pii-masking/src/main/java/com/demo/PIIMaskingApplication.java
package com.demo;

import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.streams.KafkaStreams;
import org.apache.kafka.streams.StreamsBuilder;
import org.apache.kafka.streams.StreamsConfig;
import org.apache.kafka.streams.Topology;
import org.apache.kafka.streams.kstream.KStream;
import org.apache.kafka.streams.kstream.Produced;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.regex.Pattern;

public class PIIMaskingApplication {
    private static final Logger logger = LoggerFactory.getLogger(PIIMaskingApplication.class);
    private static final ObjectMapper objectMapper = new ObjectMapper();
    
    // PII patterns
    private static final Pattern EMAIL_PATTERN = Pattern.compile(
        "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"
    );
    private static final Pattern SSN_PATTERN = Pattern.compile(
        "^\\d{3}-\\d{2}-\\d{4}$"
    );
    private static final Pattern PHONE_PATTERN = Pattern.compile(
        "^\\+?1?\\d{10,14}$"
    );
    private static final Pattern CREDIT_CARD_PATTERN = Pattern.compile(
        "^\\d{4}[\\s-]?\\d{4}[\\s-]?\\d{4}[\\s-]?\\d{4}$"
    );
    
    public static void main(String[] args) {
        Properties props = getStreamsConfig();
        
        StreamsBuilder builder = new StreamsBuilder();
        
        // Process customers topic
        processCustomersTopic(builder);
        
        // Process orders topic
        processOrdersTopic(builder);
        
        // Process products topic (pass-through, no PII)
        processProductsTopic(builder);
        
        Topology topology = builder.build();
        logger.info("Topology: {}", topology.describe());
        
        KafkaStreams streams = new KafkaStreams(topology, props);
        
        // Add shutdown hook
        CountDownLatch latch = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(new Thread("streams-shutdown-hook") {
            @Override
            public void run() {
                streams.close();
                latch.countDown();
            }
        });
        
        try {
            streams.start();
            latch.await();
        } catch (Throwable e) {
            logger.error("Error in streams application", e);
            System.exit(1);
        }
        System.exit(0);
    }
    
    private static Properties getStreamsConfig() {
        Properties props = new Properties();
        
        // Required configs
        props.put(StreamsConfig.APPLICATION_ID_CONFIG, "pii-masking-app");
        props.put(StreamsConfig.BOOTSTRAP_SERVERS_CONFIG, 
            System.getenv().getOrDefault("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092"));
        
        // Serialization
        props.put(StreamsConfig.DEFAULT_KEY_SERDE_CLASS_CONFIG, Serdes.String().getClass());
        props.put(StreamsConfig.DEFAULT_VALUE_SERDE_CLASS_CONFIG, JsonSerde.class);
        
        // Performance configs
        props.put(StreamsConfig.NUM_STREAM_THREADS_CONFIG, 4);
        props.put(StreamsConfig.PROCESSING_GUARANTEE_CONFIG, StreamsConfig.EXACTLY_ONCE_V2);
        props.put(StreamsConfig.CACHE_MAX_BYTES_BUFFERING_CONFIG, 10 * 1024 * 1024L);
        props.put(StreamsConfig.COMMIT_INTERVAL_MS_CONFIG, 1000);
        
        // Consumer configs
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.MAX_POLL_RECORDS_CONFIG, 1000);
        
        // MSK IAM authentication
        if ("true".equals(System.getenv("USE_MSK_IAM"))) {
            props.put("security.protocol", "SASL_SSL");
            props.put("sasl.mechanism", "AWS_MSK_IAM");
            props.put("sasl.jaas.config", 
                "software.amazon.msk.auth.iam.IAMLoginModule required;");
        }
        
        return props;
    }
    
    private static void processCustomersTopic(StreamsBuilder builder) {
        KStream<String, JsonNode> customersStream = builder.stream("oracle.inventory.customers");
        
        KStream<String, JsonNode> maskedStream = customersStream
            .mapValues(value -> maskCustomerPII(value))
            .filter((key, value) -> value != null);
        
        maskedStream.to("oracle.inventory.customers.masked", 
            Produced.with(Serdes.String(), new JsonSerde()));
            
        // Log sample records for monitoring
        maskedStream.peek((key, value) -> {
            if (Math.random() < 0.01) { // Log 1% of records
                logger.info("Masked customer record: key={}, operation={}", 
                    key, value.path("payload").path("op").asText());
            }
        });
    }
    
    private static void processOrdersTopic(StreamsBuilder builder) {
        KStream<String, JsonNode> ordersStream = builder.stream("oracle.inventory.orders");
        
        // Orders might contain PII in notes or comments
        KStream<String, JsonNode> maskedStream = ordersStream
            .mapValues(value -> maskOrderPII(value))
            .filter((key, value) -> value != null);
        
        maskedStream.to("oracle.inventory.orders.masked", 
            Produced.with(Serdes.String(), new JsonSerde()));
    }
    
    private static void processProductsTopic(StreamsBuilder builder) {
        // Products typically don't contain PII, just pass through
        builder.stream("oracle.inventory.products")
            .to("oracle.inventory.products.masked");
    }
    
    private static JsonNode maskCustomerPII(JsonNode cdcRecord) {
        try {
            ObjectNode mutableRecord = cdcRecord.deepCopy();
            JsonNode payload = mutableRecord.path("payload");
            
            if (payload.isMissingNode()) {
                return mutableRecord;
            }
            
            // Mask data in 'after' field (for inserts/updates)
            if (payload.has("after") && !payload.path("after").isNull()) {
                ObjectNode after = (ObjectNode) payload.path("after");
                maskFieldsInRecord(after);
            }
            
            // Mask data in 'before' field (for updates/deletes)
            if (payload.has("before") && !payload.path("before").isNull()) {
                ObjectNode before = (ObjectNode) payload.path("before");
                maskFieldsInRecord(before);
            }
            
            return mutableRecord;
        } catch (Exception e) {
            logger.error("Error masking customer PII", e);
            return null;
        }
    }
    
    private static JsonNode maskOrderPII(JsonNode cdcRecord) {
        try {
            ObjectNode mutableRecord = cdcRecord.deepCopy();
            JsonNode payload = mutableRecord.path("payload");
            
            if (payload.isMissingNode()) {
                return mutableRecord;
            }
            
            // Check for PII in order comments or notes
            if (payload.has("after") && !payload.path("after").isNull()) {
                ObjectNode after = (ObjectNode) payload.path("after");
                
                // Mask any comments that might contain email or phone
                if (after.has("comments")) {
                    String comments = after.get("comments").asText();
                    String maskedComments = maskTextForPII(comments);
                    after.put("comments", maskedComments);
                }
            }
            
            return mutableRecord;
        } catch (Exception e) {
            logger.error("Error masking order PII", e);
            return null;
        }
    }
    
    private static void maskFieldsInRecord(ObjectNode record) {
        // Email masking
        if (record.has("email")) {
            String email = record.get("email").asText();
            record.put("email", maskEmail(email));
        }
        
        // SSN tokenization
        if (record.has("ssn")) {
            String ssn = record.get("ssn").asText();
            record.put("ssn", tokenizeSSN(ssn));
        }
        
        // Phone masking
        if (record.has("phone")) {
            String phone = record.get("phone").asText();
            record.put("phone", maskPhone(phone));
        }
        
        // Credit card masking
        if (record.has("credit_card")) {
            String cc = record.get("credit_card").asText();
            record.put("credit_card", maskCreditCard(cc));
        }
        
        // Name partial masking (keep first letter)
        if (record.has("first_name")) {
            String firstName = record.get("first_name").asText();
            record.put("first_name", partialMask(firstName));
        }
        
        if (record.has("last_name")) {
            String lastName = record.get("last_name").asText();
            record.put("last_name", partialMask(lastName));
        }
    }
    
    private static String maskEmail(String email) {
        if (email == null || !EMAIL_PATTERN.matcher(email).matches()) {
            return email;
        }
        
        String[] parts = email.split("@");
        if (parts.length != 2) {
            return email;
        }
        
        String localPart = parts[0];
        String domain = parts[1];
        
        // Keep first and last char of local part
        String maskedLocal;
        if (localPart.length() <= 2) {
            maskedLocal = "***";
        } else {
            maskedLocal = localPart.charAt(0) + "***" + localPart.charAt(localPart.length() - 1);
        }
        
        return maskedLocal + "@" + domain;
    }
    
    private static String tokenizeSSN(String ssn) {
        if (ssn == null || !SSN_PATTERN.matcher(ssn).matches()) {
            return ssn;
        }
        
        try {
            // Create a deterministic token using SHA-256
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest(ssn.getBytes());
            
            // Convert to hex and take first 8 characters
            StringBuilder token = new StringBuilder("TOKEN-");
            for (int i = 0; i < 4; i++) {
                token.append(String.format("%02x", hash[i]));
            }
            
            return token.toString().toUpperCase();
        } catch (Exception e) {
            logger.error("Error tokenizing SSN", e);
            return "TOKEN-ERROR";
        }
    }
    
    private static String maskPhone(String phone) {
        if (phone == null || phone.length() < 10) {
            return phone;
        }
        
        // Keep country code and last 4 digits
        if (phone.length() >= 10) {
            String lastFour = phone.substring(phone.length() - 4);
            String prefix = phone.startsWith("+") ? phone.substring(0, 3) : "";
            return prefix + "****" + lastFour;
        }
        
        return phone;
    }
    
    private static String maskCreditCard(String cc) {
        if (cc == null || cc.length() < 12) {
            return cc;
        }
        
        // Remove spaces and dashes
        String cleaned = cc.replaceAll("[\\s-]", "");
        
        if (cleaned.length() >= 12) {
            String lastFour = cleaned.substring(cleaned.length() - 4);
            return "**** **** **** " + lastFour;
        }
        
        return cc;
    }
    
    private static String partialMask(String name) {
        if (name == null || name.isEmpty()) {
            return name;
        }
        
        if (name.length() == 1) {
            return name;
        }
        
        return name.charAt(0) + "***";
    }
    
    private static String maskTextForPII(String text) {
        if (text == null) {
            return text;
        }
        
        // Simple regex-based masking for emails in text
        text = text.replaceAll(
            "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
            "***@***.***"
        );
        
        // Mask phone numbers
        text = text.replaceAll(
            "\\+?1?\\d{10,14}",
            "***-***-****"
        );
        
        return text;
    }
}

// applications/pii-masking/src/main/java/com/demo/JsonSerde.java
package com.demo;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.kafka.common.serialization.Deserializer;
import org.apache.kafka.common.serialization.Serde;
import org.apache.kafka.common.serialization.Serializer;

import java.util.Map;

public class JsonSerde implements Serde<JsonNode> {
    private final ObjectMapper objectMapper = new ObjectMapper();
    
    @Override
    public Serializer<JsonNode> serializer() {
        return new Serializer<JsonNode>() {
            @Override
            public byte[] serialize(String topic, JsonNode data) {
                try {
                    return objectMapper.writeValueAsBytes(data);
                } catch (Exception e) {
                    throw new RuntimeException("Error serializing JSON", e);
                }
            }
        };
    }
    
    @Override
    public Deserializer<JsonNode> deserializer() {
        return new Deserializer<JsonNode>() {
            @Override
            public JsonNode deserialize(String topic, byte[] data) {
                try {
                    return objectMapper.readTree(data);
                } catch (Exception e) {
                    throw new RuntimeException("Error deserializing JSON", e);
                }
            }
        };
    }
}
