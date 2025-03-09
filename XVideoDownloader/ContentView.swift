import SwiftUI
import Foundation
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
	@State private var videoURL = ""
	@State private var downloadPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
	@State private var isDownloading = false
	@State private var downloadProgress: Float = 0.0
	@State private var statusMessage = "Готов к загрузке"
	@State private var showAlert = false
	@State private var alertTitle = ""
	@State private var alertMessage = ""
	
	private let ytdlpDownloader = YTDLPDownloader()
	
	// Для выбора папки
	@State private var showingFolderPicker = false
	
	var body: some View {
		VStack(alignment: .leading, spacing: 20) {
			Text("X Video Downloader")
				.font(.largeTitle)
				.fontWeight(.bold)
				.padding(.bottom, 10)
			
			VStack(alignment: .leading) {
				Text("URL видео с X/Twitter:")
					.font(.headline)
				
				TextField("https://x.com/...", text: $videoURL)
					.textFieldStyle(RoundedBorderTextFieldStyle())
					.disableAutocorrection(true)
			}
			
			VStack(alignment: .leading) {
				Text("Папка для сохранения:")
					.font(.headline)
				
				HStack {
					Text(downloadPath)
						.lineLimit(1)
						.truncationMode(.middle)
						.padding(10)
						.background(Color.gray.opacity(0.1))
						.cornerRadius(5)
					
					Button(action: {
						showingFolderPicker = true
					}) {
						Text("Выбрать")
							.frame(width: 80)
					}
					.buttonStyle(.bordered)
				}
			}
			
			VStack(alignment: .leading, spacing: 5) {
				ProgressView(value: Double(downloadProgress), total: 1.0)
					.progressViewStyle(LinearProgressViewStyle())
				
				Text(statusMessage)
					.font(.subheadline)
					.foregroundColor(isDownloading ? .blue : .primary)
			}
			
			HStack {
				Spacer()
				
				Button(action: {
					Task {
						await downloadVideo()
					}
				}) {
					Text("Загрузить видео")
						.frame(minWidth: 120)
				}
				.buttonStyle(.borderedProminent)
				.disabled(videoURL.isEmpty || isDownloading)
			}
		}
		.padding()
		.frame(width: 500, height: 320)
		.fileImporter(
			isPresented: $showingFolderPicker,
			allowedContentTypes: [UTType.folder],
			allowsMultipleSelection: false
		) { result in
			do {
				guard let selectedFolder = try result.get().first else { return }
				downloadPath = selectedFolder.path
			} catch {
				showAlert(title: "Ошибка", message: "Не удалось выбрать папку: \(error.localizedDescription)")
			}
		}
		.alert(isPresented: $showAlert) {
			Alert(
				title: Text(alertTitle),
				message: Text(alertMessage),
				dismissButton: .default(Text("OK"))
			)
		}
	}
	
	func downloadVideo() async {
		guard !videoURL.isEmpty, isValidURL(videoURL) else {
			showAlert(title: "Ошибка", message: "Пожалуйста, введите корректный URL видео X/Twitter")
			return
		}
		
		// Проверка на X/Twitter URL
		guard videoURL.contains("twitter.com") || videoURL.contains("x.com") else {
			showAlert(title: "Ошибка", message: "URL должен быть с сайта X/Twitter")
			return
		}
		
		DispatchQueue.main.async {
			isDownloading = true
			statusMessage = "Подготовка..."
			downloadProgress = 0.1
		}
		
		do {
			DispatchQueue.main.async {
				statusMessage = "Скачивание yt-dlp..."
			}
			
			// Запускаем загрузку с отслеживанием прогресса
			let downloadedFile = try await ytdlpDownloader.downloadVideo(
				url: videoURL,
				destinationFolder: downloadPath
			) { progress in
				DispatchQueue.main.async {
					downloadProgress = 0.3 + (progress * 0.7) // от 30% до 100%
					statusMessage = "Загрузка: \(Int(progress * 100))%"
				}
			}
			
			DispatchQueue.main.async {
				downloadProgress = 1.0
				statusMessage = "Загрузка завершена!"
				isDownloading = false
				showAlert(title: "Успех", message: "Видео успешно загружено: \(downloadedFile.path)")
				videoURL = ""
				
				// Открываем файл в Finder
				NSWorkspace.shared.selectFile(downloadedFile.path, inFileViewerRootedAtPath: "")
			}
		} catch {
			DispatchQueue.main.async {
				statusMessage = "Ошибка загрузки"
				isDownloading = false
				downloadProgress = 0.0
				showAlert(title: "Ошибка загрузки", message: error.localizedDescription)
			}
		}
	}
	
	func checkAndInstallYTDLP() async {
		let task = Process()
		task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
		task.arguments = ["yt-dlp"]
		
		let outputPipe = Pipe()
		task.standardOutput = outputPipe
		
		do {
			try task.run()
			task.waitUntilExit()
			
			if task.terminationStatus != 0 {
				// yt-dlp не установлен, устанавливаем
				try await installYTDLP()
			}
		} catch {
			// Ошибка при проверке, пробуем установить
			try? await installYTDLP()
		}
	}
	
	func installYTDLP() async throws {
		let task = Process()
		task.executableURL = URL(fileURLWithPath: "/usr/bin/pip3")
		task.arguments = ["install", "yt-dlp"]
		
		let errorPipe = Pipe()
		task.standardError = errorPipe
		
		do {
			try task.run()
			task.waitUntilExit()
			
			if task.terminationStatus != 0 {
				let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
				let errorString = String(data: errorData, encoding: .utf8) ?? "Неизвестная ошибка"
				throw NSError(domain: "XVideoDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ошибка установки yt-dlp: \(errorString)"])
			}
		} catch {
			throw NSError(domain: "XVideoDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось установить yt-dlp: \(error.localizedDescription)"])
		}
	}
	
	func startDownload() async throws {
		let task = Process()
		task.executableURL = URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
		task.arguments = [
			"-o", "\(downloadPath)/%(title)s.%(ext)s",
			"-f", "best",
			videoURL
		]
		
		let outputPipe = Pipe()
		let errorPipe = Pipe()
		task.standardOutput = outputPipe
		task.standardError = errorPipe
		
		do {
			try task.run()
			
			// Отслеживаем прогресс через stdout
			let outputHandle = outputPipe.fileHandleForReading
			outputHandle.readabilityHandler = { handle in
				let data = handle.availableData
				if let output = String(data: data, encoding: .utf8), !output.isEmpty {
					DispatchQueue.main.async {
						if output.contains("%") {
							if let progressStr = output.components(separatedBy: " ").first(where: { $0.contains("%") }),
							   let progressVal = Float(progressStr.replacingOccurrences(of: "%", with: "")) {
								downloadProgress = min(0.9, progressVal / 100.0 + 0.3)
							}
						}
						statusMessage = "Загрузка: \(Int(downloadProgress * 100))%"
					}
				}
			}
			
			task.waitUntilExit()
			
			// Проверяем код завершения
			if task.terminationStatus != 0 {
				let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
				let errorString = String(data: errorData, encoding: .utf8) ?? "Неизвестная ошибка"
				throw NSError(domain: "XVideoDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ошибка загрузки видео: \(errorString)"])
			}
		} catch {
			throw NSError(domain: "XVideoDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить загрузку: \(error.localizedDescription)"])
		}
	}
	
	func isValidURL(_ urlString: String) -> Bool {
		guard let url = URL(string: urlString) else { return false }
		return url.scheme != nil && url.host != nil
	}
	
	func showAlert(title: String, message: String) {
		DispatchQueue.main.async {
			alertTitle = title
			alertMessage = message
			showAlert = true
		}
	}
}
