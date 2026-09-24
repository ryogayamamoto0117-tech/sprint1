package com.example.sprint1;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import java.util.List;

@RestController
public class DbController {

    private final JdbcTemplate jdbcTemplate;

    public DbController(JdbcTemplate jdbcTemplate){
        this.jdbcTemplate = jdbcTemplate;
    }

    @GetMapping("/db-test")
    public String dbTest(){
        String topic = jdbcTemplate.queryForObject(
            "SELECT topic FROM records LIMIT 1", 
            String.class
        );
        return topic;
    }
    @PostMapping("/records")
    public String createRecord(@RequestBody Record record){

        jdbcTemplate.update(
            "INSERT INTO records (topic, memo) VALUES (?, ?)",
            record.getTopic(),
            record.getMemo()
        );

        return "saved";
    }    

    @GetMapping("/records")
    public List<Record> getRecords() {

        return jdbcTemplate.query(
            "SELECT id, topic, memo FROM records ORDER BY id DESC",
            (rs, rowNum) -> {
                Record record = new Record();
                record.setId(rs.getLong("id"));
                record.setTopic(rs.getString("topic"));
                record.setMemo(rs.getString("memo"));
                return record;
            }
        );
    }     

    

}