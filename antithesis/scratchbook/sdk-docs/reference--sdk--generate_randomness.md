# Generate randomness
Antithesis runs your tests in a deterministic simulation, so any random number generator (RNG) you consult will give the same sequence of answers in every test run.

Since we wish to explore many possibilities over the course of each test, Antithesis provides ways for your software -- either your test template or your actual software -- to request inputs that can be used in place of an RNG to make random decisions.

The most straightforward way to do this is from the system random devices, which we override and replace with our own source of entropy. But the SDKs offer an alternative source that is both more convenient and more structured.

Use of SDK random functions is usually more convenient than opening and reading from system random devices. The SDK also offers higher-level, more "structured" random methods, for example the equivalent of the Python standard library's [random.choice()](https://docs.python.org/3/library/random.html#random.choice). These are not provided only for convenience, they also make it easier for Antithesis to learn what sorts of inputs to provide.

Suppose you have a randomized test template that runs one of three tests, `a()`, `b()`, and `c()`. Suppose that test `c()` is ineffective, and rarely or never provokes interesting behavior in your system. If you use an SDK random function to decide which test to run, then over time Antithesis will learn that inputs which result in `c()` running are less fruitful, and will not provide them as often. But it is much easier to learn this if you tell Antithesis that you are making a choice between three options, as opposed to requesting a 64-bit number and computing its value modulo 3.

A corollary of this is that you should **never** take inputs returned by SDK random functions and use them to seed your own RNG, or store them to make a decision later. Either one of these anti-patterns makes it harder for Antithesis to learn to control your software, and defeats the purpose of using the SDK.
