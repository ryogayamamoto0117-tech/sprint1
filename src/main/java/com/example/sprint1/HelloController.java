package com.example.sprint1;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController{

    @GetMapping("/")
    public String home(){
        return "Hello Sprint 1!";
    }

    @GetMapping("/health")
    public String health(){
        return "OK";
    }
}