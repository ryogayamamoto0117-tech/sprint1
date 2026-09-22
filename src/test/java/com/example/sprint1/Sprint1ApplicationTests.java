package com.example.sprint1;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;

@WebMvcTest(HelloController.class)
class Sprint1ApplicationTests {

	@Autowired
	private MockMvc mockMvc;

	@Test
	void healthReturnOK() throws Exception{

		mockMvc.perform(get("/health"))
		       .andExpect(status().isOk())
			   .andExpect(content().string("OK"));
	}

}
