using System.Text.Json;

namespace AgApproval;

public sealed record PricingProfile(
    string ProfileName,
    string DisplayLabel,
    decimal Multiplier,
    decimal InputPerMillionUsd,
    decimal CachedInputPerMillionUsd,
    decimal OutputPerMillionUsd,
    string UpdatedAt,
    string? Note)
{
    public static PricingProfile Default { get; } = new(
        ProfileName: "gpt-6-luna-low-2x-estimate",
        DisplayLabel: "GPT-6 Luna 低思考 × 2（估算）",
        Multiplier: 2.0m,
        InputPerMillionUsd: 0.10m,
        CachedInputPerMillionUsd: 0.01m,
        OutputPerMillionUsd: 0.50m,
        UpdatedAt: "2026-11-21",
        Note: "估算计价：暂按 OpenAI GPT-6 Luna 低思考模式标准价（输入 $0.10/1M，缓存输入 $0.01/1M，输出含推理 $0.50/1M）的 2 倍折算。"
    );

    public static PricingProfile Load(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            return Default;
        try
        {
            var profile = JsonSerializer.Deserialize<PricingProfile>(File.ReadAllText(path), Json.Options);
            if (profile == null) return Default;
            if (profile.Multiplier < 0m || profile.InputPerMillionUsd < 0m ||
                profile.CachedInputPerMillionUsd < 0m || profile.OutputPerMillionUsd < 0m)
                return Default;
            return profile;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            return Default;
        }
    }

    public decimal EstimateUsd(long inputTokens, long? cachedInputTokens, long outputTokens)
    {
        long input = Math.Max(0, inputTokens);
        long output = Math.Max(0, outputTokens);
        decimal baseUsd;
        if (cachedInputTokens.HasValue)
        {
            long cached = Math.Clamp(cachedInputTokens.Value, 0, input);
            long uncached = Math.Max(0, input - cached);
            baseUsd = (uncached * InputPerMillionUsd + cached * CachedInputPerMillionUsd + output * OutputPerMillionUsd) / 1_000_000m;
        }
        else
        {
            baseUsd = (input * InputPerMillionUsd + output * OutputPerMillionUsd) / 1_000_000m;
        }
        return Math.Round(baseUsd * Multiplier, 6, MidpointRounding.AwayFromZero);
    }
}
