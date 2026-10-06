package ru.hyperion.fixtures;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class AppTest {
    @Test
    void greets() {
        assertEquals("hello, ci", App.greeting("ci"));
    }
}
