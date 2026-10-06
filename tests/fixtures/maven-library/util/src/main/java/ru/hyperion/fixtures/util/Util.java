package ru.hyperion.fixtures.util;

import ru.hyperion.fixtures.core.Core;

/** Модуль, зависящий от core. */
public final class Util {
    private Util() {
    }

    /**
     * Удвоение через Core.
     *
     * @param a число
     * @return удвоенное число
     */
    public static int twice(int a) {
        return Core.add(a, a);
    }
}
