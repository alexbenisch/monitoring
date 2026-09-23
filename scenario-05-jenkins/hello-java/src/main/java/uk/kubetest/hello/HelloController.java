package uk.kubetest.hello;

import java.time.Instant;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    // Injected from application.yaml, which reads it from the environment.
    // The deployment sets it from the image tag, so the running pod can tell
    // you which build it came from - the cheapest possible answer to "did my
    // pipeline actually deploy anything?".
    private final String buildTag;

    public HelloController(@Value("${app.build-tag}") String buildTag) {
        this.buildTag = buildTag;
    }

    @GetMapping("/hello")
    public Map<String, String> hello() {
        return Map.of(
                "message", "hello from the pipeline",
                "build", buildTag,
                "at", Instant.now().toString());
    }
}
