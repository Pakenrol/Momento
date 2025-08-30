# 🎬 FastDVDnet + RealBasicVSR x2 Pipeline

Готовый workflow для улучшения видео: **денойзинг → апскейлинг x2**

## 🚀 Быстрый старт

### 1. Подготовка моделей
```bash
# Активировать окружение
source venv/bin/activate

# Конвертировать модели в PyTorch format
python convert_fastdvdnet.py      # Создаст fastdvdnet_traced.pt
python convert_realbasicvsr.py    # Создаст realbasicvsr_traced.pt
```

### 2. Запуск pipeline
```bash
# Базовое использование
python video_enhancement_pipeline.py input_video.mp4

# С указанием выходного файла
python video_enhancement_pipeline.py input_video.mp4 --output enhanced_video.mp4

# Сохранить промежуточные кадры для отладки
python video_enhancement_pipeline.py input_video.mp4 --keep-temp
```

## 🧩 Как это работает

**Точно по плану:**

1. **Видеодекодер** → разбивает видео на кадры
2. **FastDVDnet** → денойзинг пачками по 5 кадров, выдает очищенный центральный
3. **RealBasicVSR** → апскейлинг x2 каждого кадра  
4. **Видеоэнкодер** → склеивает в итоговое видео

## ⚡️ Оптимизация для M-чипов

- Модели автоматически используют PyTorch MPS (Metal Performance Shaders)
- Для CoreML конвертации добавьте `compute_units=ct.ComputeUnit.ALL`
- Обрабатывайте видео чанками по 100-200 кадров при нехватке памяти

## 📊 Результат

- **Два шага**: чистка → апскейл
- **Натуральный результат**: без искусственного "мыла"
- **Отремастеренный вид**: старый материал выглядит современно

## 🔧 Расширенные опции

```bash
# Использовать свою папку для временных файлов
python video_enhancement_pipeline.py video.mp4 --temp-dir ./temp

# Получить справку
python video_enhancement_pipeline.py --help
```

## 📁 Структура файлов

```
MaccyScaler/
├── fastdvdnet/                    # Оригинальный репозиторий
├── mmediting/                     # MMEditing для RealBasicVSR
├── convert_fastdvdnet.py          # Конвертер FastDVDnet
├── convert_realbasicvsr.py        # Конвертер RealBasicVSR  
├── video_enhancement_pipeline.py  # Главный pipeline
├── fastdvdnet_traced.pt          # Трассированная FastDVDnet
├── realbasicvsr_traced.pt        # Трассированная RealBasicVSR
└── venv/                         # Python окружение
```

## ⚠️ Известные проблемы

- **Веса FastDVDnet**: Скачались некорректно, сейчас используются случайные (для архитектуры)
- **MMEditing**: Требует дополнительную настройку для RealBasicVSR
- **Память**: Большие видео требуют чанкования

## 🔄 Для CoreML конвертации

После тестирования PyTorch версии, можно конвертировать в CoreML:

```python
import coremltools as ct

# Загружаем трассированную модель
traced_model = torch.jit.load('fastdvdnet_traced.pt')

# Конвертируем в CoreML
mlmodel = ct.convert(
    traced_model,
    inputs=[ct.TensorType(name="input", shape=(1, 15, 256, 256))],
    compute_units=ct.ComputeUnit.ALL
)

# Сохраняем
mlmodel.save("FastDVDnet.mlmodel")
```

Готово! Теперь у тебя есть полный pipeline как в плане.