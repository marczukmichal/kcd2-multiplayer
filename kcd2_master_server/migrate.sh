#!/bin/bash

read -p "Migration message: " message

flask --app run.py db migrate -m "$message"
flask --app run.py db upgrade
