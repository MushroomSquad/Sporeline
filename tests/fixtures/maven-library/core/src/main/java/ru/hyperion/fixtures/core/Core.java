package ru.hyperion.fixtures.core;

/** Пример модуля библиотеки. */
public final class Core {
    private Core() {
    }

    /**
     * Сумма двух чисел.
     *
     * @param a первое слагаемое
     * @param b второе слагаемое
     * @return сумма
     */
    public static int add(int a, int b) {
        return a + b;
    }
}
