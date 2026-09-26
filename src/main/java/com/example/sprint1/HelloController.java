package com.example.sprint1;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.beans.factory.annotation.Value;

@RestController
public class HelloController{

    @GetMapping("/")
    public String home(){
        return "Hello Sprint 3 v2!";
    }

    @GetMapping("/health")
    public String health(){
        return "OK";
    }

    @Value("${INSTANCE_NAME:unknown}")
    private String instanceName;

    @GetMapping("/instance")
    public String instance(){
        return instanceName;
    }

}