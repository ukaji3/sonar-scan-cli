import os
import hashlib
import subprocess


# Bug: SQL injection vulnerability
def get_user(username):
    import sqlite3
    conn = sqlite3.connect("users.db")
    query = "SELECT * FROM users WHERE name = '" + username + "'"
    return conn.execute(query)


# Security: hardcoded password
DB_PASSWORD = "SuperSecret123!"
API_KEY = "AKIAIOSFODNN7EXAMPLE"


# Bug: mutable default argument
def append_item(item, target=[]):
    target.append(item)
    return target


# Code smell: unused variable, too many branches
def process(data):
    unused_var = 42
    result = None
    if data == 1:
        result = "one"
    elif data == 2:
        result = "two"
    elif data == 3:
        result = "three"
    elif data == 4:
        result = "four"
    elif data == 5:
        result = "five"
    elif data == 6:
        result = "six"
    elif data == 7:
        result = "seven"
    elif data == 8:
        result = "eight"
    elif data == 9:
        result = "nine"
    elif data == 10:
        result = "ten"
    elif data == 11:
        result = "eleven"
    return result


# Bug: broad exception catch
def read_file(path):
    try:
        with open(path) as f:
            return f.read()
    except:
        pass


# Security: command injection
def run_command(user_input):
    os.system("echo " + user_input)
    subprocess.call(user_input, shell=True)


# Bug: comparison using 'is' with literal
def check_value(x):
    if x is 1:
        return True
    return False


# Code smell: dead code after return
def compute(a, b):
    return a + b
    result = a * b
    return result


# Security: weak hash
def hash_password(password):
    return hashlib.md5(password.encode()).hexdigest()


# Bug: empty function body without docstring explanation
def placeholder():
    pass
