import Foundation

class YTDLPDownloader {
	enum DownloaderError: Error, LocalizedError {
		case downloadFailed(String)
		case permissionsError
		case fileOperationFailed(String)
		
		var errorDescription: String? {
			switch self {
			case .downloadFailed(let reason):
				return "Ошибка загрузки yt-dlp: \(reason)"
			case .permissionsError:
				return "Ошибка прав доступа при настройке yt-dlp"
			case .fileOperationFailed(let reason):
				return "Ошибка при работе с файлами: \(reason)"
			}
		}
	}
	
	private var ytdlpPath: URL?
	
	// Проверяет, скачан ли yt-dlp
	func isDownloaded() -> Bool {
		if let path = ytdlpPath {
			return FileManager.default.fileExists(atPath: path.path)
		}
		return false
	}
	
	// Загружает yt-dlp и возвращает путь к исполняемому файлу
	func downloadYTDLP() async throws -> URL {
		// Создаем папку в поддиректории приложения
		let appSupportDir = try FileManager.default.url(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)
		
		let ytdlpDir = appSupportDir.appendingPathComponent("ytdlp", isDirectory: true)
		if !FileManager.default.fileExists(atPath: ytdlpDir.path) {
			try FileManager.default.createDirectory(at: ytdlpDir, withIntermediateDirectories: true)
		}
		
		let destinationPath = ytdlpDir.appendingPathComponent("yt-dlp")
		
		// Загружаем последнюю версию yt-dlp с GitHub
		let ytdlpURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp")!
		
		let (fileURL, _) = try await URLSession.shared.download(from: ytdlpURL)
		
		// Перемещаем загруженный файл в папку приложения
		if FileManager.default.fileExists(atPath: destinationPath.path) {
			try FileManager.default.removeItem(at: destinationPath)
		}
		
		try FileManager.default.moveItem(at: fileURL, to: destinationPath)
		
		// Делаем файл исполняемым только через chmod
		do {
			// Используем chmod для установки разрешений
			let process = Process()
			process.executableURL = URL(fileURLWithPath: "/bin/chmod")
			process.arguments = ["+x", destinationPath.path]
			
			try process.run()
			process.waitUntilExit()
			
			if process.terminationStatus != 0 {
				throw DownloaderError.permissionsError
			}
		} catch {
			throw DownloaderError.fileOperationFailed("Не удалось установить права на выполнение: \(error.localizedDescription)")
		}
		
		ytdlpPath = destinationPath
		return destinationPath
	}
	
	// Получает или загружает yt-dlp
	func getOrDownloadYTDLP() async throws -> URL {
		if let path = ytdlpPath, FileManager.default.fileExists(atPath: path.path) {
			return path
		}
		
		return try await downloadYTDLP()
	}
	
	// Скачивает видео с помощью локальной копии yt-dlp
	func downloadVideo(url: String, destinationFolder: String, progressCallback: @escaping (Float) -> Void) async throws -> URL {
		let ytdlpPath = try await getOrDownloadYTDLP()
		
		let process = Process()
		process.executableURL = ytdlpPath
		
		// Создаем временный скрипт-обертку для запуска yt-dlp
		let wrapperScriptURL = try createWrapperScript(for: ytdlpPath)
		
		process.executableURL = URL(fileURLWithPath: "/bin/bash")
		process.arguments = [
			wrapperScriptURL.path,
			"-o", "%(title).40s.%(ext)s",
			"--paths", destinationFolder,
			"-f", "b",
			"--print", "after_move:filepath",
			url
		]
		
		let outputPipe = Pipe()
		let errorPipe = Pipe()
		process.standardOutput = outputPipe
		process.standardError = errorPipe
		
		var finalOutput = ""
		
		let outputHandle = outputPipe.fileHandleForReading
		outputHandle.readabilityHandler = { handle in
			let data = handle.availableData
			guard !data.isEmpty else { return }
			
			if let output = String(data: data, encoding: .utf8) {
				// Обновляем прогресс, если можем найти его в выводе
				if output.contains("[download]") && output.contains("%") {
					if let percentRange = output.range(of: #"\d+\.\d+%"#, options: .regularExpression) {
						let percentString = output[percentRange].replacingOccurrences(of: "%", with: "")
						if let percent = Float(percentString) {
							progressCallback(percent / 100.0)
						}
					}
				} else if !output.contains("[download]") && !output.contains("%") {
					finalOutput += output.trimmingCharacters(in: .whitespacesAndNewlines)
				}
			}
		}
		
		do {
			try process.run()
			process.waitUntilExit()
			
			// Очистка обработчика
			outputHandle.readabilityHandler = nil
			
			// Проверяем код выхода
			if process.terminationStatus != 0 {
				let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
				let errorString = String(data: errorData, encoding: .utf8) ?? "Неизвестная ошибка"
				throw DownloaderError.downloadFailed(errorString)
			}
			
			// Если имя файла не получено от вывода, читаем остаток данных
			if finalOutput.isEmpty {
				let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
				finalOutput = String(data: outputData, encoding: .utf8) ?? ""
				finalOutput = finalOutput.trimmingCharacters(in: .whitespacesAndNewlines)
			}
			
			let path = URL(fileURLWithPath: finalOutput)
			// Проверяем существование файла
			if FileManager.default.fileExists(atPath: path.path) {
				// Удаляем временный скрипт
				try? FileManager.default.removeItem(at: wrapperScriptURL)
				return path
			} else {
				// Ищем файл в папке назначения
				let filename = path.lastPathComponent
				let possiblePath = URL(fileURLWithPath: destinationFolder).appendingPathComponent(filename)
				
				if FileManager.default.fileExists(atPath: possiblePath.path) {
					try? FileManager.default.removeItem(at: wrapperScriptURL)
					return possiblePath
				}
				throw DownloaderError.downloadFailed("Файл не найден по указанному пути: \(path.path)")
			}
		} catch let error as DownloaderError {
			// Удаляем временный скрипт в случае ошибки
			try? FileManager.default.removeItem(at: wrapperScriptURL)
			throw error
		} catch {
			// Удаляем временный скрипт в случае ошибки
			try? FileManager.default.removeItem(at: wrapperScriptURL)
			throw DownloaderError.downloadFailed(error.localizedDescription)
		}
	}
	
	// Создает временный bash-скрипт для запуска yt-dlp
	private func createWrapperScript(for ytdlpPath: URL) throws -> URL {
		let tempScriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("ytdlp_wrapper.sh")
		
		let scriptContent = """
		#!/bin/bash
		export PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
		export PYTHONPATH=""
		"\(ytdlpPath.path)" "$@"
		"""
		
		try scriptContent.write(to: tempScriptURL, atomically: true, encoding: .utf8)
		
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/bin/chmod")
		process.arguments = ["+x", tempScriptURL.path]
		
		try process.run()
		process.waitUntilExit()
		
		return tempScriptURL
	}
}
