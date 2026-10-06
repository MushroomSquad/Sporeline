package main

import "testing"

func TestGreeting(t *testing.T) {
	if Greeting("ci") != "hello, ci" {
		t.Fatal("unexpected greeting")
	}
}
