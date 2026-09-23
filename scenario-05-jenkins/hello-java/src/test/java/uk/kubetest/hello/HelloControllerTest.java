package uk.kubetest.hello;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

// @WebMvcTest starts the web layer only - no server, no full context. It runs
// in about a second, which is what lets a pipeline run tests on every commit
// without anyone learning to skip them.
@WebMvcTest(HelloController.class)
@TestPropertySource(properties = "app.build-tag=test")
class HelloControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void helloReturnsTheBuildTag() throws Exception {
        mockMvc.perform(get("/hello"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.message").value("hello from the pipeline"))
                .andExpect(jsonPath("$.build").value("test"));
    }
}
