#include <Arduino.h>
#include <ESP32Servo.h>

Servo s1, s2, s3;

void setup() {
    s1.attach(4, 500, 2400);
    s2.attach(5, 500, 2400);
    s3.attach(6, 500, 2400);
}

void loop() {
    s1.write(60); 
    delay(700);
    s1.write(120); 
    delay(700);
    s1.write(90); 
    delay(700);

    s2.write(60); 
    delay(700);
    s2.write(120); 
    delay(700);
    s2.write(90); 
    delay(700);   

    s3.write(60); 
    delay(700);
    s3.write(120); 
    delay(700);
    s3.write(90); 
    delay(700);
}