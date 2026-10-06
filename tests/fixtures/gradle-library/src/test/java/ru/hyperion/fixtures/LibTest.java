package ru.hyperion.fixtures;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

class LibTest {
    @Test
    void adds() { assertEquals(3, Lib.add(1, 2)); }
}
