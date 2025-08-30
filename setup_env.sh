#!/bin/bash
# Скрипт для настройки окружения Python для MaccyScaler

echo "🔧 Настройка окружения для MaccyScaler..."

# Удаляем старое окружение
rm -rf venv

# Создаем новое виртуальное окружение с Python 3.11 (совместимость)
python3 -m venv venv
source venv/bin/activate

echo "📦 Установка совместимых версий..."
# Устанавливаем совместимые версии для CoreML
pip install torch==2.5.0 torchvision==0.20.0

echo "📦 Установка CoreML Tools..."
pip install coremltools==7.2

echo "📦 Установка системных зависимостей..."
pip install setuptools distutils-deprecated opencv-python pillow numpy

echo "✅ Окружение настроено с совместимыми версиями!"
echo "Для активации используйте: source venv/bin/activate"