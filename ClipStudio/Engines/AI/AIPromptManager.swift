//
//  AIPromptManager.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  Every instruction, prompt, JSON schema and function declaration sent to the
//  model lives here (versioned), so behaviour is consistent and reviewable:
//  • system instructions per task (Arabic answers by default);
//  • structured-output schemas (Gemini responseSchema, OpenAPI subset);
//  • editing-assistant function declarations (mapped 1:1 to AIEditOperation);
//  • compact text descriptions of the timeline / media given as context.
//

import Foundation

enum AIPromptManager {
    static let version = 1

    // MARK: System instructions

    static func system(for task: AITask, language: AIResponseLanguage) -> String {
        let common = """
        أنت مساعد مونتاج فيديو داخل تطبيق ClipStudio على آيفون/آيباد. \
        كن دقيقًا ومختصرًا. لا تخترع ملفات أو أوقاتًا غير موجودة: استخدم فقط المراجع والأوقات المعطاة (بالثواني). \
        \(language.instruction)
        """
        switch task {
        case .storyboard:
            return common + "\nمهمتك: تصميم قصة مصورة (Storyboard) قصيرة وجذابة من فكرة المستخدم ومن الوسائط المتاحة (m1، m2…). اختر لقطات حقيقية من الوسائط مع أوقات بداية ونهاية داخل مدة كل ملف. ابدأ بخطّاف قوي في أول 3 ثوانٍ."
        case .highlights:
            return common + "\nمهمتك: إيجاد أفضل اللحظات في فيديو طويل (حركة، ضحك، ذروة، كلام مهم، لقطة جميلة). كل لحظة لها بداية ونهاية بالثواني داخل مدة الفيديو، ودرجة من 0 إلى 100، وعنوان قصير وسبب."
        case .content:
            return common + "\nمهمتك: كتابة محتوى نشر لكل منصة (عنوان، وصف، هاشتاقات، خطّاف للثواني الأولى، نص للصورة المصغرة) مناسب لطبيعة كل منصة وحدودها، اعتمادًا على كلام الفيديو ونصوصه فقط."
        case .assistant:
            return common + """

            مهمتك: تنفيذ طلبات المونتاج عبر استدعاء الدوال المتاحة فقط. \
            المقاطع مرقمة c1، c2… والمسارات t1، t2… والأوقات على الخط الزمني بالثواني. \
            استدعِ كل الدوال اللازمة دفعة واحدة. إذا كان الطلب سؤالًا أو غير واضح فأجب بنص قصير بدون دوال. \
            لا تحذف شيئًا لم يطلبه المستخدم.
            """
        case .transcriptCleanup:
            return common + "\nمهمتك: اقتراح أجزاء من الكلام تُحذف لتحسين الفيديو: كلمات الحشو، التكرار، التلعثم والأخطاء المصححة، والكلام الخارج عن الموضوع. أعد أرقام الكلمات (من البداية إلى النهاية شاملة). كن محافظًا: لا تقترح حذف معلومات مهمة."
        case .styleEnrichment:
            return common + "\nمهمتك: وصف أسلوب المونتاج البصري لفيديو مرجعي من صوره: المزاج، نوع الانتقالات، شكل الترجمة، والألوان كقيم تعديل من -100 إلى 100."
        case .connectionTest:
            return "أجب بكلمة واحدة فقط: جاهز"
        case .translation:
            return "أنت مترجم محترف لترجمات الفيديو (Subtitles). ترجم بدقة وبأسلوب طبيعي مختصر يناسب القراءة السريعة على الشاشة. أعد نفس عدد السطور وبنفس الترتيب دائمًا، ولا تدمج أو تقسم السطور، ولا تضف شروحًا."
        case .hookCheck:
            return common + "\nمهمتك: تقييم قوة أول 3 ثوانٍ من فيديو قصير (الخطّاف): هل تجذب المشاهد ليكمل؟ انظر للصورة الأولى والنص والكلام والحركة. كن صريحًا وعمليًا، واقترح تعديلات قابلة للتنفيذ."
        case .shorten:
            return common + "\nمهمتك: اختصار فيديو كلامي إلى مدة محددة باختيار الجمل الأهم فقط مع الحفاظ على المعنى والتسلسل وبداية قوية ونهاية واضحة. أعد أرقام الجمل المختارة فقط."
        }
    }

    // MARK: Schemas

    private static func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "OBJECT", "properties": properties, "required": required]
    }

    private static let string: [String: Any] = ["type": "STRING"]
    private static let number: [String: Any] = ["type": "NUMBER"]
    private static let integer: [String: Any] = ["type": "INTEGER"]
    private static let boolean: [String: Any] = ["type": "BOOLEAN"]

    private static func array(_ items: [String: Any]) -> [String: Any] { ["type": "ARRAY", "items": items] }
    private static func enumeration(_ values: [String]) -> [String: Any] { ["type": "STRING", "enum": values] }

    static var storyboardSchema: [String: Any] {
        let shot = object(["mediaRef": string, "start": number, "end": number], required: ["mediaRef", "start", "end"])
        let scene = object([
            "purpose": enumeration(StoryboardPurpose.allCases.map(\.rawValue)),
            "description": string,
            "duration": number,
            "onScreenText": string,
            "voiceover": string,
            "shot": shot
        ], required: ["purpose", "description", "duration"])
        return object(["title": string, "summary": string, "musicMood": string, "scenes": array(scene)],
                      required: ["title", "scenes"])
    }

    static var highlightsSchema: [String: Any] {
        let moment = object(["start": number, "end": number, "score": number, "title": string, "reason": string],
                            required: ["start", "end", "score", "title"])
        return object(["highlights": array(moment)], required: ["highlights"])
    }

    static func contentSchema(platforms: [SocialPlatform]) -> [String: Any] {
        let post = object([
            "platform": enumeration(platforms.map(\.rawValue)),
            "title": string,
            "caption": string,
            "hashtags": array(string),
            "hook": string,
            "thumbnailText": string
        ], required: ["platform", "title", "caption", "hashtags"])
        return object(["keywords": array(string), "posts": array(post)], required: ["posts"])
    }

    static var transcriptSchema: [String: Any] {
        let suggestion = object([
            "startWord": integer, "endWord": integer,
            "kind": enumeration(CleanupKind.allCases.map(\.rawValue)),
            "reason": string
        ], required: ["startWord", "endWord", "kind"])
        return object(["suggestions": array(suggestion)], required: ["suggestions"])
    }

    static var enrichmentSchema: [String: Any] {
        object([
            "mood": string, "description": string,
            "transitionKind": enumeration(TransitionKind.allCases.map(\.rawValue)),
            "transitionRate": number,
            "captionPreset": enumeration(CaptionStylePreset.all.map(\.id)),
            "exposure": number, "contrast": number, "saturation": number, "temperature": number, "vibrance": number
        ], required: ["mood", "description"])
    }

    // MARK: Assistant functions

    static func assistantFunctions(styleNames: [String]) -> [AIFunctionDeclaration] {
        let clipList = array(string)
        var functions: [AIFunctionDeclaration] = [
            AIFunctionDeclaration(name: "split_at", description: "قص (تقسيم) المقاطع عند وقت على الخط الزمني.",
                                  parameters: object(["time": number], required: ["time"])),
            AIFunctionDeclaration(name: "trim_clip", description: "تغيير بداية و/أو نهاية مقطع على الخط الزمني (ثوانٍ).",
                                  parameters: object(["clip": string, "start": number, "end": number], required: ["clip"])),
            AIFunctionDeclaration(name: "delete_clips", description: "حذف مقاطع. ripple=true يسد الفراغ.",
                                  parameters: object(["clips": clipList, "ripple": boolean], required: ["clips"])),
            AIFunctionDeclaration(name: "move_clip", description: "نقل مقطع ليبدأ عند وقت معين.",
                                  parameters: object(["clip": string, "time": number], required: ["clip", "time"])),
            AIFunctionDeclaration(name: "set_speed", description: "سرعة مقطع (0.25 بطيء … 4 سريع، 1 طبيعي).",
                                  parameters: object(["clip": string, "rate": number], required: ["clip", "rate"])),
            AIFunctionDeclaration(name: "add_title", description: "إضافة نص/عنوان على الفيديو.",
                                  parameters: object(["text": string, "start": number, "duration": number,
                                                      "placement": enumeration(TitlePlacement.allCases.map(\.rawValue))],
                                                     required: ["text"])),
            AIFunctionDeclaration(name: "add_transition", description: "انتقال قبل المقاطع المذكورة (فارغ = بين كل المقاطع).",
                                  parameters: object(["clips": clipList,
                                                      "kind": enumeration(TransitionKind.allCases.filter { $0 != .none }.map(\.rawValue)),
                                                      "duration": number], required: ["kind"])),
            AIFunctionDeclaration(name: "set_volume", description: "مستوى صوت مقاطع (0 صامت، 1 طبيعي، حتى 2).",
                                  parameters: object(["clips": clipList, "level": number], required: ["clips", "level"])),
            AIFunctionDeclaration(name: "adjust_color", description: "تعديل الألوان (من -100 إلى 100). clips فارغ = كل اللقطات.",
                                  parameters: object(["clips": clipList, "exposure": number, "contrast": number,
                                                      "saturation": number, "temperature": number], required: [])),
            AIFunctionDeclaration(name: "add_marker", description: "إضافة علامة على الخط الزمني.",
                                  parameters: object(["time": number, "name": string], required: ["time"])),
            AIFunctionDeclaration(name: "remove_silences", description: "حذف الوقفات الصامتة الأطول من مدة معينة.",
                                  parameters: object(["minimum_pause": number], required: [])),
            AIFunctionDeclaration(name: "normalize_audio", description: "تسوية مستوى الصوت لكل المقاطع.",
                                  parameters: nil),
            AIFunctionDeclaration(name: "duck_music", description: "خفض الموسيقى تلقائيًا عند الكلام.",
                                  parameters: nil),
            AIFunctionDeclaration(name: "stabilize", description: "تثبيت فيديو مهتز.",
                                  parameters: object(["clip": string], required: ["clip"])),
            AIFunctionDeclaration(name: "cut_to_beat", description: "قص المقاطع على إيقاع الموسيقى كل عدد من الضربات.",
                                  parameters: object(["beats": integer], required: [])),
            AIFunctionDeclaration(name: "open_tool", description: "فتح أداة: captions ترجمة، music إيقاع، quality فحص، outputs مقاسات، smartTools تتبع، editingStyle أسلوب، export تصدير.",
                                  parameters: object(["tool": enumeration(AssistantTool.allCases.map(\.rawValue))], required: ["tool"]))
        ]
        if !styleNames.isEmpty {
            functions.append(AIFunctionDeclaration(name: "apply_style", description: "تطبيق أسلوب مونتاج محفوظ.",
                                                   parameters: object(["name": enumeration(styleNames)], required: ["name"])))
        }
        return functions
    }

    // MARK: Prompt text

    static func mediaDescription(_ media: [AIMediaReference]) -> String {
        media.map { item in
            var line = item.ref + ": " + (item.kind == .image ? "صورة" : item.kind == .audio ? "صوت" : "فيديو")
                + " «" + item.name + "»"
            if item.kind != .image { line += " مدته " + String(format: "%.1f", item.duration) + " ث" }
            if !item.sceneCuts.isEmpty {
                line += " — بداية اللقطات: " + item.sceneCuts.prefix(30).map { String(format: "%.1f", $0) }.joined(separator: "، ")
            }
            if !item.transcript.isEmpty { line += "\n   الكلام: " + String(item.transcript.prefix(1_500)) }
            return line
        }.joined(separator: "\n")
    }

    static func storyboardPrompt(_ input: StoryboardInput) -> String {
        """
        الفكرة: \(input.idea.isEmpty ? "فيديو قصير ممتع من الوسائط المتاحة" : input.idea)
        المدة المطلوبة: نحو \(Int(input.targetDuration.rounded())) ثانية.
        الأسلوب: \(input.tone)
        الوسائط المتاحة (الصور المرفقة مسبوقة بمرجعها ووقتها):
        \(mediaDescription(input.media))
        أعد مشاهد مرتبة، ومجموع مددها قريب من المدة المطلوبة.
        """
    }

    static func highlightsPrompt(_ input: HighlightsInput, framesOnly: Bool) -> String {
        """
        الفيديو \(input.media.ref) «\(input.media.name)» مدته \(String(format: "%.1f", input.media.duration)) ثانية.
        المطلوب: \(input.count) لحظات، طول كل منها قرابة \(Int(input.targetLength.rounded())) ثانية (بين 2 و\(Int(max(4, input.targetLength * 2))) ثانية)، بدون تداخل.
        \(framesOnly ? "مرفق صور من الفيديو مع وقت كل صورة." : "الفيديو مرفق كاملًا.")
        \(input.sceneCuts.isEmpty ? "" : "بداية اللقطات: " + input.sceneCuts.prefix(60).map { String(format: "%.1f", $0) }.joined(separator: "، "))
        \(input.media.transcript.isEmpty ? "" : "الكلام: " + String(input.media.transcript.prefix(3_000)))
        """
    }

    static func contentPrompt(_ input: ContentInput) -> String {
        """
        المشروع: «\(input.projectName)» مدته \(Int(input.duration.rounded())) ثانية.
        المنصات: \(input.platforms.map(\.rawValue).joined(separator: "، "))
        النبرة: \(input.tone)
        لغة المنشور: \(input.language)
        الكلام في الفيديو: \(input.spokenText.isEmpty ? "(لا يوجد)" : String(input.spokenText.prefix(4_000)))
        النصوص على الشاشة: \(input.onScreenText.isEmpty ? "(لا يوجد)" : input.onScreenText.prefix(20).joined(separator: " | "))
        التزم بحدود كل منصة (X ‏280 حرفًا، سناب 250). الهاشتاقات بدون مسافات.
        """
    }

    static func assistantContext(_ context: AssistantContext) -> String {
        var lines: [String] = []
        lines.append("مدة المشروع: " + String(format: "%.2f", context.duration) + " ث، رأس التشغيل عند "
                     + String(format: "%.2f", context.playhead) + " ث، " + String(Int(context.frameRate)) + " إطار/ث.")
        lines.append("المسارات:")
        for track in context.tracks { lines.append("- " + track.ref + " (" + track.kind.rawValue + ") «" + track.name + "»") }
        lines.append("المقاطع:")
        for clip in context.clips.prefix(400) {
            var line = "- " + clip.ref + " في " + clip.trackRef + ": " + clip.kind + " «" + clip.name + "» من "
                + String(format: "%.2f", clip.start) + " إلى " + String(format: "%.2f", clip.end)
            if abs(clip.speed - 1) > 0.01 { line += " سرعة " + String(format: "%.2f", clip.speed) }
            if let text = clip.text, !text.isEmpty { line += " نص: «" + String(text.prefix(80)) + "»" }
            lines.append(line)
        }
        if !context.selectedRefs.isEmpty { lines.append("المحدد الآن: " + context.selectedRefs.joined(separator: "، ")) }
        if !context.styleNames.isEmpty { lines.append("الأساليب المحفوظة: " + context.styleNames.joined(separator: "، ")) }
        return lines.joined(separator: "\n")
    }

    static func transcriptPrompt(words: [String], gaps: [Double]) -> String {
        var tokens: [String] = []
        for (index, word) in words.enumerated() {
            tokens.append(String(index) + ":" + word)
            if index < gaps.count, gaps[index] >= 0.8 { tokens.append("[وقفة " + String(format: "%.1f", gaps[index]) + "ث]") }
        }
        return "الكلمات مرقمة (رقم:كلمة):\n" + tokens.joined(separator: " ")
    }

    static func enrichmentPrompt(_ dna: EditingDNA) -> String {
        "الصور المرفقة من فيديو مرجعي. القياسات المحلية: " + dna.summary
            + ". صف الأسلوب البصري واقترح انتقالًا وشكل ترجمة وتعديلات ألوان تقرّب لقطات المستخدم من هذا الأسلوب."
    }
}
